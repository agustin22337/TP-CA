#!/bin/bash
# Monitor sencillo para Debian/Ubuntu. Ejecutar con Bash, no con sh.

# CONFIGURACION: editar estos cuatro valores.
UMBRAL_RAM=0          # Alertar si el uso alcanza o supera este porcentaje.
PROBABILIDAD_ZOMBIE=100  # 0: desactivado; 100: siempre; 25: aprox. 25% de ejecuciones.
BOT_TOKEN=""          # Token del bot entregado por @BotFather.
CHAT_ID=""            # ID del chat del propietario del servidor.
DISCORD_WEBHOOK=""
UMBRAL_CPU=0 
# Comprobar porcentajes enteros entre 0 y 100 antes de usarlos.
for valor in "$UMBRAL_RAM" "$PROBABILIDAD_ZOMBIE" "$UMBRAL_CPU"; do
    if [[ ! "$valor" =~ ^(0|[1-9][0-9]?|100)$ ]]; then
        echo "Error: los porcentajes deben ser enteros de 0 a 100." >&2
        exit 1
    fi
done

# Comprobar que estan disponibles los comandos necesarios.
for comando in python3 curl ps awk; do
    if ! command -v "$comando" >/dev/null; then
        echo "Error: falta instalar $comando." >&2
        exit 1
    fi
done


leer_cpu() {
    awk '/^cpu / {
        total=0

        # Sumar user, nice, system, idle, iowait, irq, softirq y steal.
        # guest y guest_nice ya estan incluidos en otros campos.
        for (i=2; i<=9; i++) total+=$i

        # Considerar idle e iowait como tiempo sin ejecutar trabajo.
        print total, $5+$6
        exit
    }' /proc/stat
}

# Tomar dos mediciones separadas por un segundo.
# Los contadores son acumulados: su diferencia mide este intervalo.
read -r total_antes inactivo_antes < <(leer_cpu)
sleep 1
read -r total_despues inactivo_despues < <(leer_cpu)

diferencia_total=$((total_despues - total_antes))
diferencia_inactivo=$((inactivo_despues - inactivo_antes))

# Evitar dividir por cero o calcular con contadores invalidos.
if (( diferencia_total <= 0 ||
      diferencia_inactivo < 0 ||
      diferencia_inactivo > diferencia_total )); then
    echo "Error al medir CPU." >&2
    exit 1
fi
cpu_usada=$((100 * (diferencia_total - diferencia_inactivo) / diferencia_total))
crear_zombie() {
    # Sortear un numero entre 0 y 99 y compararlo con la probabilidad.
    if (( RANDOM % 100 < PROBABILIDAD_ZOMBIE )); then
        # Ejecutar el auxiliar en segundo plano.
        python3 - <<'PY' &
import os
import time

hijo = os.fork()             # Crear un proceso hijo.
if hijo == 0:
    os._exit(0)             # El hijo termina inmediatamente.

# Mientras el padre no recoge al hijo terminado, el hijo es zombie.
time.sleep(3)
os.waitpid(hijo, 0)         # Recogerlo automaticamente tras la prueba.
PY
        padre_prueba=$!

        # Esperar a que ps observe al hijo en estado Z.
        for (( intento=0; intento<20; intento++ )); do
            if ps --ppid "$padre_prueba" -o stat= | awk '
                /^Z/ { encontrado=1 }
                END { exit !encontrado }'; then
                echo "Zombie de prueba creado (padre PID $padre_prueba)."
                return
            fi
            sleep 0.1
        done

        echo "No se pudo observar el zombie de prueba." >&2
        exit 1
    fi
}

# Al salir, esperar al auxiliar para que termine de recoger a su hijo.
# No se modifican ni eliminan procesos ajenos.
padre_prueba=""
trap 'if [[ -n "$padre_prueba" ]]; then wait "$padre_prueba"; fi' EXIT

crear_zombie

# Medir RAM usando la memoria total y la disponible, expresadas en KiB.
# MemAvailable considera disponible la cache que puede recuperarse.
# El porcentaje se trunca a un entero y no incluye swap.
ram_usada=$(awk '
    /^MemTotal:/     { total=$2 }
    /^MemAvailable:/ { disponible=$2; encontrado=1 }
    END {
        if (total <= 0 || !encontrado) exit 1
        printf "%.0f", int(100 * (total-disponible) / total)
    }' /proc/meminfo) || {
        echo "Error al medir RAM." >&2
        exit 1
    }

# Capturar los procesos una sola vez.
# PID: identificador; PPID: identificador del padre; Z: zombie.
procesos=$(ps -eo pid=,ppid=,stat=) || {
    echo "Error al consultar procesos." >&2
    exit 1
}

zombies=$(printf '%s\n' "$procesos" | awk '$3 ~ /^Z/ { print }')
cantidad_zombies=$(printf '%s\n' "$zombies" |
    awk 'NF { n++ } END { print n+0 }')

echo "$(date '+%F %T') | CPU: ${cpu_usada}% | RAM: ${ram_usada}% | Zombies: $cantidad_zombies"

# Construir una alerta con todos los problemas detectados.
alerta=""
if (( cpu_usada >= UMBRAL_CPU )); then
    alerta+="CPU utilizada: ${cpu_usada}% (umbral: ${UMBRAL_CPU}%, muestra de 1 segundo)."$'\n'
fi
if (( ram_usada >= UMBRAL_RAM )); then
    alerta+="RAM utilizada: ${ram_usada}% (umbral: ${UMBRAL_RAM}%)."$'\n'
fi

if (( cantidad_zombies > 0 )); then
    alerta+="Procesos zombie: $cantidad_zombies."$'\n'
    alerta+="PID / PPID / ESTADO (primeros 10):"$'\n'
    alerta+="$(printf '%s\n' "$zombies" | awk 'NR <= 10')"$'\n'
fi

# Si ninguna condicion se cumple, terminar sin enviar mensajes.
if [[ -z "$alerta" ]]; then
    echo "Sin alertas."
    exit 0
fi

# Crear el mensaje ANTES de enviarlo a cualquiera de los servicios.
mensaje="ALERTA en Servidor de Computacion Avanzada - $(date '+%F %T')"$'\n'"$alerta"
echo "$mensaje"

# Registrar fallos sin impedir que se intente el otro servicio.
errores=0

# ================= DISCORD =================
if [[ -z "$DISCORD_WEBHOOK" ]]; then
    echo "Error: falta configurar DISCORD_WEBHOOK." >&2
    errores=1
else
    # Convertir el mensaje a JSON escapando comillas y saltos de linea.
    # Limitar a 2000 caracteres y desactivar menciones automaticas.
    datos_discord=$(printf '%s' "$mensaje" | python3 -c '
import json, sys
texto = sys.stdin.read()
print(json.dumps({
    "content": texto[:2000],
    "allowed_mentions": {"parse": []}
}))
')

    # wait=true solicita confirmacion de la creacion del mensaje.
    # Elegir el separador por si la URL ya contiene parametros.
    separador="?"
    if [[ "$DISCORD_WEBHOOK" == *"?"* ]]; then
        separador="&"
    fi

    if curl --silent --show-error --fail \
        --connect-timeout 10 --max-time 20 \
        -H "Content-Type: application/json" \
        --data "$datos_discord" \
        "${DISCORD_WEBHOOK}${separador}wait=true" >/dev/null; then
        echo "Alerta enviada a Discord."
    else
        echo "Error al enviar la alerta a Discord." >&2
        errores=1
    fi
fi

# ================= TELEGRAM =================
if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    echo "Error: completar BOT_TOKEN y CHAT_ID." >&2
    errores=1
else
    # Enviar mediante POST. data-urlencode conserva el formato del texto.
    if respuesta=$(curl --silent --show-error --fail \
        --connect-timeout 10 --max-time 20 \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$mensaje"); then

        # Comprobar que Telegram confirma el envio en su respuesta JSON.
        if printf '%s' "$respuesta" | python3 -c '
import json, sys
sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)
'; then
            echo "Alerta enviada por Telegram."
        else
            echo "Telegram no confirmo el envio." >&2
            errores=1
        fi
    else
        echo "Error al contactar con Telegram." >&2
        errores=1
    fi
fi

# 0: ambos servicios confirmaron; 1: hubo algun fallo de notificacion.
exit "$errores"