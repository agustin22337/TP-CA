#!/bin/bash
# Monitor para Debian/Ubuntu. Ejecutar con bash.

# 1. CONFIGURACIÓN
# Con umbral 0 siempre se genera una alerta.
UMBRAL_CPU=0
UMBRAL_RAM=0

# 0: sin zombie de prueba; 100: crear uno en cada ejecución.
PROBABILIDAD_ZOMBIE=100

DISCORD_WEBHOOK=""
BOT_TOKEN=""
CHAT_ID=""

GMAIL_USUARIO=""
GMAIL_CLAVE_APP=""
MAIL_DESTINO=""

# 2. VALIDACIONES Y FUNCIONES COMUNES
fallar() {
    echo "Error: $*" >&2
    exit 1
}

# Opciones compartidas por Discord y Telegram.
http() {
    curl --silent --show-error --fail \
        --connect-timeout 10 --max-time 20 "$@"
}

# Ejecutar un envío y registrar su resultado.
# Un fallo no interrumpe los otros canales.
registrar_envio() {
    local canal="$1"
    shift

    if "$@"; then
        echo "$canal: OK."
    else
        echo "$canal: error de configuración o envío." >&2
        errores=1
    fi
}

# 3. MEDICIÓN DE CPU
leer_cpu() {
    awk '/^cpu / {
        for (i=2; i<=9; i++) total+=$i
        printf "%.0f %.0f\n", total, $5+$6
        exit
    }' /proc/stat
}

read -r total1 idle1 < <(leer_cpu)
sleep 1
read -r total2 idle2 < <(leer_cpu)

total=$((total2 - total1))
idle=$((idle2 - idle1))

(( total > 0 && idle >= 0 && idle <= total )) ||
    fallar "al medir CPU."

cpu_usada=$((100 * (total - idle) / total))

# 4. ZOMBIE DE PRUEBA
# Al terminar el script, esperar al auxiliar.
padre_prueba=""
trap 'if [[ -n "$padre_prueba" ]]; then wait "$padre_prueba"; fi' EXIT

if (( RANDOM % 100 < PROBABILIDAD_ZOMBIE )); then
    python3 - <<'PY' &
import os
import time

hijo = os.fork()

if hijo == 0:
    os._exit(0)

# El hijo permanece zombie hasta que el padre lo recoge.
time.sleep(3)
os.waitpid(hijo, 0)
PY

    padre_prueba=$!
    observado=0

    # Esperar hasta observar el estado Z.
    for ((intento=0; intento<20; intento++)); do
        if ps --ppid "$padre_prueba" -o stat= |
            awk '/^Z/ { z=1 } END { exit !z }'; then
            observado=1
            break
        fi
        sleep 0.1
    done

    (( observado )) ||
        fallar "no se pudo observar el zombie de prueba."

    echo "Zombie de prueba creado (padre PID $padre_prueba)."
fi

# 5. MEDICIÓN DE RAM Y CONSULTA DE PROCESOS
ram_usada=$(awk '
    /^MemTotal:/ { total=$2 }
    /^MemAvailable:/ { disponible=$2; encontrado=1 }
    END {
        if (total <= 0 || !encontrado) exit 1
        print int(100 * (total-disponible) / total)
    }' /proc/meminfo) || fallar "al medir RAM."

# Consultar todos los procesos una sola vez.
procesos=$(ps -eo pid=,ppid=,stat=) ||
    fallar "al consultar procesos."

zombies=$(awk '$3 ~ /^Z/' <<< "$procesos")

cantidad_zombies=$(awk '
    NF { n++ }
    END { print n+0 }
' <<< "$zombies")

echo "$(date '+%F %T') | CPU: ${cpu_usada}% | RAM: ${ram_usada}% | Zombies: $cantidad_zombies"

# 6. CONSTRUIR UNA ALERTA CON TODOS LOS PROBLEMAS
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
    alerta+="$(awk 'NR <= 10' <<< "$zombies")"$'\n'
fi

if [[ -z "$alerta" ]]; then
    echo "Sin alertas."
    exit 0
fi

mensaje="ALERTA en Servidor de Computación Avanzada - $(date '+%F %T')"$'\n'"$alerta"
printf '%s\n' "$mensaje"

# 7. ENVÍO A DISCORD
enviar_discord() {
    [[ -n "$DISCORD_WEBHOOK" ]] || return 1

    local datos separador="?"

    # Escapar el texto para JSON y respetar el límite de Discord.
    datos=$(printf '%s' "$mensaje" | python3 -c '
import json, sys

print(json.dumps({
    "content": sys.stdin.read()[:2000],
    "allowed_mentions": {"parse": []}
}))
') || return 1

    [[ "$DISCORD_WEBHOOK" == *\?* ]] && separador="&"

    http -H "Content-Type: application/json" \
        --data "$datos" \
        "${DISCORD_WEBHOOK}${separador}wait=true" >/dev/null
}

# 8. ENVÍO A TELEGRAM
enviar_telegram() {
    [[ -n "$BOT_TOKEN" && -n "$CHAT_ID" ]] || return 1

    local respuesta

    respuesta=$(http \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$mensaje") || return 1

    # Comprobar la confirmación de Telegram.
    printf '%s' "$respuesta" | python3 -c '
import json, sys

sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)
'
}

# 9. ENVÍO DE CORREO POR GMAIL
enviar_correo() {
    [[ -n "$GMAIL_USUARIO" &&
       -n "$GMAIL_CLAVE_APP" &&
       -n "$MAIL_DESTINO" ]] || return 1

    # Pasar los datos a Python mediante variables de entorno.
    GMAIL_USUARIO="$GMAIL_USUARIO" \
    GMAIL_CLAVE_APP="$GMAIL_CLAVE_APP" \
    MAIL_DESTINO="$MAIL_DESTINO" \
    MENSAJE="$mensaje" python3 - <<'PY'
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

try:
    correo = EmailMessage()
    correo["From"] = os.environ["GMAIL_USUARIO"]
    correo["To"] = os.environ["MAIL_DESTINO"]
    correo["Subject"] = "Alerta del monitor del servidor"
    correo.set_content(os.environ["MENSAJE"])

    with smtplib.SMTP("smtp.gmail.com", 587, timeout=20) as smtp:
        # Cifrar la conexión y verificar el certificado.
        smtp.starttls(context=ssl.create_default_context())

        # Autenticarse usando la contraseña de aplicación.
        smtp.login(
            os.environ["GMAIL_USUARIO"],
            os.environ["GMAIL_CLAVE_APP"]
        )

        smtp.send_message(correo)

except Exception as error:
    print(f"Error SMTP: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

# 10. INTENTAR LOS TRES CANALES
errores=0

registrar_envio "Discord" enviar_discord
registrar_envio "Telegram" enviar_telegram
registrar_envio "Correo" enviar_correo

# 0: sin fallos; 1: falló algún canal.
exit "$errores"