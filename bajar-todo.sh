#!/usr/bin/env bash
# =============================================================================
# bajar-todo.sh - Apaga TODOS los contenedores de desarrollo de esta maquina
# =============================================================================
# Incluye los del stack compartido y los sueltos de la epoca de un compose por proyecto,
# que siguen ocupando puertos aunque ya nadie los use.
#
#   ./bajar-todo.sh          lista lo que va a parar y pide confirmacion
#   ./bajar-todo.sh --si     sin preguntar
#
# NUNCA borra volumenes. Los datos se conservan siempre. Para borrarlos hay que pedirlo
# explicitamente y por separado:
#     docker compose -f compose-dev.yaml down -v
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

# `docker stop` y no `pkill`: en esta maquina conviven varios dev servers y agentes, y un
# patron amplio de pkill ya mato el proceso de alguien mas. Aqui solo se tocan
# contenedores, cada uno por su nombre exacto.

arriba=$(docker ps --format '{{.Names}}' | sort)

if [[ -z "$arriba" ]]; then
    echo "No hay ningun contenedor corriendo."
    exit 0
fi

echo "Contenedores que se van a parar:"
echo "$arriba" | sed 's/^/    /'
echo

if [[ "${1:-}" != "--si" ]]; then
    read -r -p "Parar los $(echo "$arriba" | wc -l | tr -d ' ') contenedores? [s/N] " respuesta
    [[ "$respuesta" == "s" || "$respuesta" == "S" ]] || { echo "Cancelado."; exit 0; }
fi

# Primero la infraestructura por compose, para que Compose actualice su propio estado y un
# `ps` posterior no muestre servicios fantasma. Las APIs y los frontends de cada producto
# los levanta el compose de SU repositorio, asi que desde aqui no se pueden bajar por
# compose: se paran por nombre mas abajo, con el resto.
echo "==> Bajando la infraestructura compartida"
docker compose -f compose-dev.yaml down --remove-orphans 2>/dev/null || true

# Lo que quede es de los composes viejos de cada repo, de un `docker run` a mano, o de
# alguna otra sesion. Se paran por nombre, sin borrarlos: `docker start <nombre>` los
# devuelve tal cual estaban.
restantes=$(docker ps -q)
if [[ -n "$restantes" ]]; then
    echo "==> Parando los que quedan (contenedores sueltos, fuera del stack)"
    docker ps --format '    {{.Names}}'
    docker stop $restantes >/dev/null
fi

echo
echo "==> Listo. Nada corriendo:"
docker ps --format 'table {{.Names}}\t{{.Status}}'
echo
echo "Los datos se conservan. Para volver a levantar:"
echo "    docker compose -f compose-dev.yaml up -d"
