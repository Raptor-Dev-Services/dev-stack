#!/bin/sh
# Instala la limpieza diaria de los runners de actions-runner-2 (limpiar-runners.sh, 05:00 de Ciudad de
# Mexico). Correr con sudo, una vez en CADA maquina (build y staging), desde la copia del repo que se queda:
#     sudo sh actions-runner-2/mantenimiento/instalar-limpiar-runners.sh
# Se llama limpiar-runners-2 para convivir con la de ../../mantenimiento (actions-runner v1) si alguna
# maquina tiene las dos.
set -eu
[ "$(id -u)" = 0 ] || { echo "Correr con sudo." >&2; exit 1; }
USUARIO="${SUDO_USER:?Correr con sudo desde el usuario de los runners, no como root directo}"
CARPETA="$(cd "$(dirname "$0")" && pwd)"
sed -e "s|@USUARIO@|$USUARIO|g" -e "s|@CARPETA@|$CARPETA|g" "$CARPETA/limpiar-runners-2.service" \
  > /etc/systemd/system/limpiar-runners-2.service
cp "$CARPETA/limpiar-runners-2.timer" /etc/systemd/system/limpiar-runners-2.timer
systemctl daemon-reload
systemctl enable --now limpiar-runners-2.timer
systemctl --no-pager list-timers limpiar-runners-2.timer
echo "Corre como $USUARIO: $CARPETA/limpiar-runners.sh"
echo "Bitacora de cada corrida: journalctl -u limpiar-runners-2.service"
