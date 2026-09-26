#!/bin/sh
# =============================================================================
# crear-buckets.sh - Los buckets de cada producto en el MinIO compartido
# =============================================================================
# Corre en el contenedor `minio-init`, que arranca despues de MinIO, hace su trabajo y
# se apaga. Los buckets salen de la ultima columna de /devstack/productos.conf.
# Idempotente: `mc mb --ignore-existing` no falla si el bucket ya esta, asi que corre en
# cada `up` sin efecto -- y a diferencia de Postgres, un producto nuevo si se recoge.
#
# TODOS LOS BUCKETS SON PRIVADOS. Ninguno lleva politica de lectura anonima, a proposito:
# las lecturas se sirven con URLs prefirmadas de vida corta. Si algun dia hace falta un
# bucket publico, que sea uno nuevo y explicito, no un `anonymous set download` sobre estos.
set -eu

CONF=/devstack/productos.conf

if [ ! -f "$CONF" ]; then
    echo "ERROR: falta productos.conf. Copia productos.conf.example a productos.conf" >&2
    exit 1
fi

echo "==> Esperando a MinIO"
# El healthcheck del compose ya lo cubre, pero `mc alias set` es lo que confirma que
# ademas las credenciales son las correctas: un MinIO sano con la clave equivocada dejaria
# los buckets sin crear y el fallo apareceria mucho despues, al subir un archivo.
until mc alias set local "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
  sleep 1
done

echo "==> Creando buckets"
# Shell puro, sin grep ni awk: la imagen de minio no los trae, y en un pipe su
# "command not found" no tumba el script -- salia con 0 sin haber creado nada.
creados=0
while read -r base _ _ _ _ buckets _; do
    case "$base" in ''|'#'*) continue ;; esac
    [ "$buckets" = "-" ] && continue
    viejo_ifs=$IFS; IFS=,
    for bucket in $buckets; do
        mc mb --ignore-existing "local/$bucket" >/dev/null
        echo "    $bucket"
        creados=$((creados + 1))
    done
    IFS=$viejo_ifs
done < "$CONF"

if [ "$creados" -eq 0 ]; then
    echo "ERROR: productos.conf no declara ningun bucket" >&2
    exit 1
fi

echo "==> $creados buckets listos"
mc ls local
