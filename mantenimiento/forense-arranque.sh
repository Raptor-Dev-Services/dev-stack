#!/bin/sh
# Al arrancar, anota como termino el arranque ANTERIOR: apagado limpio o caida. Ver mantenimiento/CUELGUES.md.
# Lo corre forense-arranque.service una vez por arranque. Escribe en /var/log/arranques.log (append) con sync.
set -u
LOG=/var/log/arranques.log
AHORA=$(date -u +%FT%TZ)

# Inicio y fin del arranque anterior, segun journald.
LINEA=$(journalctl --list-boots --no-pager 2>/dev/null | awk '$1=="-1"')
if [ -z "$LINEA" ]; then
    echo "$AHORA sin arranque anterior en el journal" >> "$LOG"; sync "$LOG"; exit 0
fi
FIN_EPOCH=$(journalctl -b -1 -n 1 -o short-unix --no-pager 2>/dev/null | awk 'NR==1{print int($1)}')
FIN=$(date -u -d "@$FIN_EPOCH" +%FT%TZ 2>/dev/null || echo desconocido)

# Limpio = systemd llego al apagado (systemd-shutdown o journald recibio SIGTERM de PID 1).
if journalctl -b -1 --no-pager -n 300 2>/dev/null | grep -qE 'systemd-shutdown|Received SIGTERM from PID 1|Reached target (reboot|poweroff)\.target'; then
    TIPO=LIMPIO
else
    TIPO=CAIDA
fi

# Lo ultimo que anoto el vigia antes del fin (misma marca de minuto o anterior).
VIGIA=$(awk -v fin="$(date -u -d "@$FIN_EPOCH" +%FT%T 2>/dev/null)" '$1<=fin' /var/log/vigia.log 2>/dev/null | tail -1)

# Rastros del kernel: volcado de kdump o pstore.
CRASH=$(ls /var/crash 2>/dev/null | grep -v kdump_lock | tr '\n' ' ')
PSTORE=$(ls /sys/fs/pstore 2>/dev/null | tr '\n' ' ')

{
    echo "== $AHORA arranque nuevo; el anterior termino $FIN: $TIPO"
    echo "   anterior: $LINEA"
    echo "   vigia: ${VIGIA:-sin lectura}"
    echo "   kdump: ${CRASH:-nada}   pstore: ${PSTORE:-nada}"
    echo "   ultimas lineas del journal:"
    journalctl -b -1 -n 3 --no-pager -o short-iso 2>/dev/null | cut -c1-200 | sed 's/^/     /'
} >> "$LOG"
sync "$LOG"
