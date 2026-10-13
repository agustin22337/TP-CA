# Monitor de RAM y procesos zombie

El archivo `monitor_servidor.sh` mide la RAM y detecta procesos zombie. Si la RAM
alcanza el umbral o hay al menos un zombie, envia una sola alerta por Telegram.
Si el problema continua, vuelve a avisar en cada ejecucion de cron.

## 1. Instalar y configurar

En Debian/Ubuntu:

```bash
sudo apt update
sudo apt install curl python3 procps cron
sudo systemctl enable --now cron
mkdir -p "$HOME/monitor"
cp monitor_servidor.sh "$HOME/monitor/"
chmod 700 "$HOME/monitor/monitor_servidor.sh"
nano "$HOME/monitor/monitor_servidor.sh"
```

Editar las cuatro variables del principio:

- `UMBRAL_RAM=80`: alerta desde 80% inclusive. Acepta enteros de 0 a 100.
- `PROBABILIDAD_ZOMBIE=0`: prueba desactivada. Usar 100 para crear un zombie
  en cada ejecucion o 25 para una probabilidad aproximada de 25%.
- `BOT_TOKEN`: token de tu propio bot.
- `CHAT_ID`: identificador del chat del propietario del servidor.

## 2. Preparar Telegram

1. Hablar con el bot oficial `@BotFather` en Telegram y usar `/newbot`.
2. Copiar el token en `BOT_TOKEN`.
3. Abrir el chat con el nuevo bot y enviar `/start` y un mensaje.
4. Ejecutar el siguiente comando localmente, reemplazando TU_TOKEN:

```bash
curl --silent 'https://api.telegram.org/botTU_TOKEN/getUpdates'
```

En la respuesta buscar `message` -> `chat` -> `id`. Copiar ese numero
en `CHAT_ID` entre comillas. El comando sirve para un bot nuevo que no tenga
otro programa consumiendo las actualizaciones ni un webhook configurado.
No compartir el archivo con el token real en la entrega o exposicion.

## 3. Ejecutar y probar

```bash
bash "$HOME/monitor/monitor_servidor.sh"
```

Para probar RAM, poner `UMBRAL_RAM=0` y `PROBABILIDAD_ZOMBIE=0`: enviara
una alerta sin necesidad de consumir mas memoria.

Para probar zombies, poner `UMBRAL_RAM=100` y `PROBABILIDAD_ZOMBIE=100`:
creara un zombie real y lo detectara. Su padre lo recoge automaticamente
despues de tres segundos. La salida muestra el PID del padre y el listado
PID / PPID / ESTADO. Z indica zombie.

Para probar la condicion combinada, poner ambos valores en 0 y 100,
respectivamente. Se enviara un unico mensaje con los dos problemas.

Al finalizar la demo, restaurar `UMBRAL_RAM=80` y `PROBABILIDAD_ZOMBIE=0`.
El script no corrige el consumo de RAM ni elimina zombies ajenos: los notifica.

## 4. Cron cada 30 minutos

Consultar tu ruta absoluta:

```bash
echo "$HOME/monitor/monitor_servidor.sh"
crontab -e
```

Agregar esta linea, reemplazando USUARIO por tu usuario real y usando la ruta
obtenida. En un crontab personal no se agrega el nombre de usuario como campo:

```cron
*/30 * * * * /bin/bash /home/USUARIO/monitor/monitor_servidor.sh >> /home/USUARIO/monitor/monitor.log 2>&1
```

Se ejecuta a los minutos 00 y 30 de cada hora. `>>` agrega la salida al registro
y `2>&1` agrega tambien los errores. No requiere sudo para crear este crontab.

Comprobar la configuracion y consultar las ejecuciones:

```bash
crontab -l
tail -f "$HOME/monitor/monitor.log"
```

Para demostrar cron sin esperar media hora, cambiar temporalmente `*/30` por
`*`: ejecuta cada minuto. Luego restaurar `*/30`.

## 5. Como explicarlo

1. Las variables iniciales permiten configurar el script.
2. `crear_zombie` hace un sorteo usando RANDOM. Solo si corresponde, Python
   crea un hijo con fork que termina inmediatamente. El padre espera tres
   segundos antes de llamar a waitpid: durante ese intervalo el hijo es zombie.
   Bash suele recoger sus propios hijos terminados; por eso se usa Python.
3. `awk` lee MemTotal y MemAvailable desde `/proc/meminfo`. Calcula
   `(total - disponible) * 100 / total`, truncado a un porcentaje entero.
   La cache recuperable se considera disponible. No incluye swap.
4. `ps` obtiene una captura de los procesos. `awk` selecciona estados que
   empiezan con Z y cuenta las filas. La captura detecta zombies presentes
   en ese instante; procesos transitorios entre ejecuciones pueden no verse.
5. Los `if` arman el mensaje cuando cualquiera de las condiciones se cumple.
6. `curl` envia un POST a sendMessage con chat_id y text. Python comprueba
   el campo ok de la respuesta JSON. Si falla, el script termina con codigo 1.
7. Cron lo vuelve a ejecutar cada 30 minutos y registra su salida.

Pruebas realizadas: sintaxis Bash; ausencia de alerta; alerta de RAM;
porcentaje invalido; rechazo de la API. La creacion y deteccion del zombie
no pudo verificarse en este entorno: ps falla por un error de su biblioteca
y una lectura alternativa de /proc tampoco permitio observarlo.
Se debe confirmar la prueba de zombies en Debian/Ubuntu.
El envio se probo con una respuesta simulada: el envio real
requiere tu bot, tu chat y conexion a Telegram. Cron debe verificarse en el
servidor donde se instale.

Documentacion: https://core.telegram.org/bots/api#sendmessage
