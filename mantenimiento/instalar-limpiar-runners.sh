#!/bin/sh
# Instala la limpieza diaria de los runners (limpiar-runners.sh, 05:00 de Ciudad de Mexico).
# Correr con sudo, una vez:  sudo sh mantenimiento/instalar-limpiar-runners.sh
set -eu
cd "$(dirname "$0")"
cp limpiar-runners.service /etc/systemd/system/limpiar-runners.service
cp limpiar-runners.timer /etc/systemd/system/limpiar-runners.timer
systemctl daemon-reload
systemctl enable --now limpiar-runners.timer
systemctl --no-pager list-timers limpiar-runners.timer
echo "Bitacora de cada corrida: journalctl -u limpiar-runners.service"
