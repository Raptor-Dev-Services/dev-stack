#!/usr/bin/env bash
# =============================================================================
# disco-ci.sh - Un segundo disco para lo regenerable del server (montado el 2026-10-15)
# =============================================================================
# Formatea un disco ENTERO y lo deja como "disco de basura": las carpetas de trabajo de los runners y las
# caches de paquetes. Todo lo que va ahi se regenera solo; si el disco muere, se pierde tiempo de build,
# no datos.
#
# Como queda:
#   - El disco, en ext4 con etiqueta `ci-datos`, montado en PUNTO (default /mnt/ci-datos).
#   - Cada carpeta de CARPETAS se COPIA ahi, se vacia en el disco principal y se engancha con un bind mount
#     en su ruta de siempre. Ni los runners ni los pipelines cambian de configuracion.
#   - Todo en /etc/fstab con `nofail`: si el disco falla, el server arranca igual (con las carpetas vacias
#     en el disco principal, que se vuelven a llenar solas).
#
# Por que bind mounts y no mover RUNNERS_DIR: el entrypoint de los runners exige que RUNNERS_DIR viva
# dentro de HOST_HOME, porque monta el home del host en su misma ruta. Un symlink a /mnt rompe dentro del
# contenedor (/mnt no esta montado ahi); un bind mount dentro del home si se ve, porque Docker monta el
# home de forma recursiva. Ojo: los runners tienen que (re)arrancar DESPUES de montar.
#
# Lo que NO va a este disco: /var/lib/docker (imagenes y volumenes). Ahi viven tambien Postgres, MinIO y
# Harbor; moverlo es cambiar el data-root de todo Docker y se planea aparte.
#
# Uso (con los runners detenidos: `cd actions-runner && docker compose stop`):
#   ls -l /dev/disk/by-id/              # identifica el disco por modelo y serie
#   sudo DISCO=/dev/disk/by-id/ata-<modelo>_<serie> bash mantenimiento/disco-ci.sh
#   cd actions-runner && docker compose start
#
# BORRA TODO EL CONTENIDO DE DISCO. Se pide por /dev/disk/by-id a proposito: /dev/sdX puede cambiar de
# letra entre arranques; el modelo y la serie no.
# Variables opcionales: PUNTO, USUARIO (default el que llamo a sudo), CARPETAS (separadas por espacio,
# relativas al home de USUARIO; default "ci-runners .cache .nuget .npm").
# =============================================================================
set -euo pipefail

DISCO="${DISCO:?Falta DISCO=/dev/disk/by-id/... (ver ls -l /dev/disk/by-id/)}"
PUNTO="${PUNTO:-/mnt/ci-datos}"
USUARIO="${USUARIO:-${SUDO_USER:?Correlo con sudo desde tu usuario, o pasa USUARIO=}}"
CASA=$(getent passwd "$USUARIO" | cut -d: -f6)
read -r -a CARPETAS <<< "${CARPETAS:-ci-runners .cache .nuget .npm}"

[ "$(id -u)" = 0 ] || { echo "Correlo con sudo"; exit 1; }
case "$DISCO" in /dev/disk/by-id/*) ;; *) echo "DISCO tiene que ser una ruta /dev/disk/by-id/..."; exit 1 ;; esac
[ -b "$DISCO" ] || { echo "No encuentro $DISCO"; exit 1; }
if findmnt -rno SOURCE | grep -q "^$(readlink -f "$DISCO")"; then
  echo "$DISCO tiene algo montado; desmontalo antes"; exit 1
fi
grep -q " $PUNTO " /etc/fstab && { echo "$PUNTO ya esta en /etc/fstab; no repito"; exit 1; }
if [ -n "$(docker ps -q --filter label=com.docker.compose.project=actions-runner)" ]; then
  echo "Los runners siguen corriendo; detenlos antes (cd actions-runner && docker compose stop)"; exit 1
fi

echo "== Formateando $(readlink -f "$DISCO") ($DISCO) =="
wipefs -a "$DISCO"
parted -s "$DISCO" mklabel gpt mkpart ci-datos ext4 1MiB 100%
udevadm settle
PART="${DISCO}-part1"
# -m 0: sin bloques reservados para root; es un disco de datos, no el del sistema.
mkfs.ext4 -F -L ci-datos -m 0 "$PART"
UUID=$(blkid -s UUID -o value "$PART")

mkdir -p "$PUNTO"
echo "UUID=$UUID $PUNTO ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount "$PUNTO"

for c in "${CARPETAS[@]}"; do
  origen="$CASA/$c"; destino="$PUNTO/${c#.}"
  mkdir -p "$destino" "$origen"
  echo "== $origen -> $destino =="
  rsync -aHX "$origen/" "$destino/"
  # Lo copiado se borra del disco principal: quedaria escondido bajo el bind mount ocupando espacio.
  find "$origen" -mindepth 1 -delete
  chown "$USUARIO:$USUARIO" "$destino"
  echo "$destino $origen none bind,nofail,x-systemd.requires-mounts-for=$PUNTO 0 0" >> /etc/fstab
done

systemctl daemon-reload
mount -a
echo "== Listo =="
findmnt "$PUNTO"; for c in "${CARPETAS[@]}"; do findmnt "$CASA/$c"; done
df -h "$PUNTO" /
