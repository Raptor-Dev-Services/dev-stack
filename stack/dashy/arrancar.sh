#!/bin/sh
# =============================================================================
# arrancar.sh - Genera el conf.yml de Dashy desde la plantilla y arranca Dashy
# =============================================================================
# Corre dentro del contenedor, como su usuario (node). Sustituye cada NOMBRE entre arrobas
# por el valor de la variable de entorno del mismo nombre -las pasa el compose desde .env- y
# agrega productos.yml si existe. Despues hace `exec` al comando original de la imagen.
#
# Una variable que quede sin sustituir es un error, no un link roto: se aborta y se dice
# cual, en vez de publicar una pagina con el marcador del host literal adentro. Ojo: la
# comprobacion mira el ARCHIVO ENTERO, comentarios incluidos, asi que en los yml no se
# escribe un nombre entre arrobas que no sea una variable real.
set -eu

ORIGEN=/dashy-init
DESTINO=/app/user-data/conf.yml
VARIABLES="DEVSTACK_HOST GRAFANA_PORT PROMETHEUS_PORT SEQ_UI_PORT UPTIME_KUMA_PORT MINIO_CONSOLE_PORT MAILPIT_WEB_PORT"

sustituir() {
    contenido=$(cat "$1")
    for var in $VARIABLES; do
        eval "valor=\${$var:?falta $var en el entorno de dashy}"
        contenido=$(printf '%s\n' "$contenido" | sed "s|@$var@|$valor|g")
    done
    printf '%s\n' "$contenido"
}

sustituir "$ORIGEN/conf.template.yml" > "$DESTINO"

if [ -f "$ORIGEN/productos.yml" ]; then
    sustituir "$ORIGEN/productos.yml" >> "$DESTINO"
    echo "==> dashy: conf.yml generado con productos.yml"
else
    echo "==> dashy: conf.yml generado SIN productos (no existe dashy/productos.yml)"
fi

if grep -n '@[A-Z_]*@' "$DESTINO"; then
    echo "ERROR: quedaron variables sin sustituir en conf.yml (lineas arriba)" >&2
    exit 1
fi

exec node server.js
