#!/bin/sh
# Prueba de RAM desde SSH con memtester, cubriendo lo mas posible de los 30 GB.
# Ver mantenimiento/CUELGUES.md, "Como correr la prueba de RAM".
#
# Uso (como root, dentro de tmux para que sobreviva a un corte de SSH):
#   tmux new -s ram
#   sudo sh mantenimiento/probar-ram.sh [pasadas]     # por omision 2
#
# Que hace:
#   1. Para Docker (TODO staging, Harbor, el dev-stack y los runners quedan apagados) para liberar memoria.
#   2. Toma la memoria disponible y deja 1.5 GB para el sistema; prueba el resto con memtester.
#   3. Escribe el resultado en /var/log/memtester-<fecha>.log con sync, para que sobreviva a una caida.
#   4. Al terminar (bien o mal) vuelve a levantar Docker.
#
# Limite que NO se puede quitar: la memoria que ocupa el kernel no se prueba. Para los 30 GB completos hace
# falta memtest86+ arrancado desde GRUB (con monitor).
set -u

PASADAS="${1:-2}"
RESERVA_MB=1536
LOG="/var/log/memtester-$(date -u +%Y%m%dT%H%M%SZ).log"

if [ "$(id -u)" -ne 0 ]; then
    echo "Correr con sudo: memtester necesita root para bloquear la memoria (mlock)." >&2
    exit 1
fi
command -v memtester >/dev/null 2>&1 || apt-get install -y memtester

anota() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; sync "$LOG"; }

YA_LEVANTADO=0
levantar_docker() {
    [ "$YA_LEVANTADO" -eq 1 ] && return
    YA_LEVANTADO=1
    anota "Levantando Docker otra vez"
    systemctl start docker.socket docker.service
    # Harbor no vuelve solo: sus contenedores arrancan antes que harbor-log y mueren (ver CUELGUES.md).
    if [ -d /home/raptor/Docker/harbor ]; then
        sleep 20
        (cd /home/raptor/Docker/harbor && docker compose up -d) >>"$LOG" 2>&1
    fi
}
trap levantar_docker EXIT
trap 'exit 130' INT TERM

anota "Parando Docker (staging, Harbor, dev-stack y runners quedan apagados)"
systemctl stop docker.service docker.socket containerd.service 2>>"$LOG"
sync
echo 3 > /proc/sys/vm/drop_caches

DISPONIBLE_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
TOTAL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
PRUEBA_MB=$((DISPONIBLE_MB - RESERVA_MB))
anota "Memoria total ${TOTAL_MB} MB, disponible ${DISPONIBLE_MB} MB; se prueban ${PRUEBA_MB} MB en ${PASADAS} pasada(s)"

memtester "${PRUEBA_MB}M" "$PASADAS" 2>&1 | while IFS= read -r linea; do
    printf '%s\n' "$linea" >> "$LOG"
    sync "$LOG"
    printf '%s\n' "$linea"
done
CODIGO=$(grep -c 'FAILURE' "$LOG")

if [ "$CODIGO" -gt 0 ]; then
    anota "RESULTADO: HAY ERRORES DE MEMORIA (ver FAILURE arriba). La RAM esta mal."
else
    anota "RESULTADO: sin errores en ${PRUEBA_MB} MB y ${PASADAS} pasada(s)."
fi
anota "Log completo: $LOG"
