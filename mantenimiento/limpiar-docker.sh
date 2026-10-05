#!/usr/bin/env bash
# =============================================================================
# limpiar-docker.sh - Limpieza segura del Docker del server (pedida el 2026-10-05)
# =============================================================================
# Los runners de GitHub comparten el Docker del server con el stack (Postgres, MinIO, Redis, Harbor, el
# monitoreo) y con las APIs de staging. Por eso NO se usa `docker system prune`: con `--volumes` borraria los
# datos de un servicio que estuviera detenido un momento, y sin filtros borraria lo que otro build en paralelo
# esta usando. Lo que hace este script, y nada mas:
#
#   1. Contenedores detenidos hace mas de 24 h, EXCEPTO los de un proyecto de compose (el stack, los runners,
#      staging): un servicio del stack apagado a proposito no se toca.
#   2. Imagenes "colgadas" (sin etiqueta, restos de builds anteriores) con mas de 24 h.
#   3. De las imagenes PROPIAS (las del registro Harbor y las imagenes de build locales), conserva las
#      CONSERVAR mas recientes de cada repositorio y borra las demas. Las imagenes base (SDK de .NET, Node,
#      Postgres...) NO se tocan: borrarlas solo obliga a bajarlas otra vez en el siguiente build.
#      Una imagen en uso no se puede borrar (`docker rmi` sin -f falla) y se deja.
#   4. Cache de build con mas de 7 dias, dejando un minimo para que los builds sigan rapidos.
#   NUNCA volumenes.
#
# Por que no `docker image prune -a --filter until=168h`: `until` mira cuando se CREO la imagen, no cuando se
# uso por ultima vez. Las imagenes base casi siempre se crearon hace mas de 7 dias y se borrarian cada noche.
#
# Uso:
#   bash mantenimiento/limpiar-docker.sh           # EN SECO: dice que borraria y no borra nada
#   bash mantenimiento/limpiar-docker.sh --real    # borra
# Variables (opcionales): CONSERVAR (default 3), CACHE_MINIMA (default 20gb), PROPIAS (patron grep -E de los
# repositorios de imagen propios; default el registro Harbor y las imagenes de build de Android).
# =============================================================================
set -euo pipefail

REAL=false
[ "${1:-}" = "--real" ] && REAL=true

CONSERVAR="${CONSERVAR:-3}"
CACHE_MINIMA="${CACHE_MINIMA:-20gb}"
PROPIAS="${PROPIAS:-^harbor\.raptorcloud\.dev/|^sociofit-android-build$}"

modo() { if $REAL; then echo "REAL"; else echo "EN SECO (no se borra nada)"; fi; }
ejecutar() {
  if $REAL; then "$@"; else echo "  [seco] $*"; fi
}

echo "== Limpieza de Docker: $(modo) =="
echo "== Espacio ANTES =="
docker system df

echo
echo "== 1. Contenedores detenidos hace mas de 24 h (fuera de compose) =="
# Se lee cada contenedor detenido con `docker inspect` (fecha en RFC 3339, formato fijo): el de compose
# lleva la etiqueta com.docker.compose.project y se deja; los demas, si terminaron hace mas de 24 h, se borran.
LIMITE=$(date -u -d '24 hours ago' +%s)
HAY=false
while read -r id; do
  [ -n "$id" ] || continue
  IFS='|' read -r terminado proyecto nombre < <(docker inspect -f     '{{.State.FinishedAt}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.Name}}' "$id")
  [ -z "$proyecto" ] || continue
  # Un contenedor que nunca arranco tiene FinishedAt en el año 1: cuenta como viejo.
  t=$(date -u -d "$terminado" +%s 2>/dev/null || echo 0)
  [ "$t" -lt "$LIMITE" ] || continue
  HAY=true
  echo "  ${nombre#/} ($id)"
  ejecutar docker rm "$id" >/dev/null || echo "  no se pudo borrar $id; se deja"
done < <(docker ps -aq --filter status=exited --filter status=created --filter status=dead)
$HAY || echo "  (ninguno)"

echo
echo "== 2. Imagenes colgadas con mas de 24 h =="
if $REAL; then
  docker image prune -f --filter "until=24h"
else
  docker images --filter dangling=true --format '  [seco] {{.ID}} {{.CreatedSince}} {{.Size}}'
fi

echo
echo "== 3. Imagenes propias: se conservan las $CONSERVAR mas recientes de cada repositorio =="
# `docker images` las da de la mas nueva a la mas vieja dentro de cada repositorio.
docker images --format '{{.Repository}} {{.Tag}} {{.ID}} {{.CreatedAt}}' \
  | awk -v patron="$PROPIAS" -v conservar="$CONSERVAR" '
      # El patron se aplica SOLO al nombre del repositorio (primer campo), no a la linea entera: con la linea
      # entera, un `$` de fin de nombre no coincidia nunca.
      $1 ~ patron && $2 != "<none>" { visto[$1]++; if (visto[$1] > conservar) print $1 ":" $2 }' \
  | while read -r ref; do
      echo "  $ref"
      # Sin -f: si un contenedor (corriendo o no) la usa, falla y se deja. Es lo que queremos.
      ejecutar docker rmi "$ref" >/dev/null 2>&1 || echo "  en uso o no se pudo borrar: $ref; se deja"
    done

echo
echo "== 4. Cache de build con mas de 7 dias (se deja un minimo de $CACHE_MINIMA) =="
# Docker 28 cambio el nombre de la opcion: --keep-storage paso a --reserved-space.
if docker builder prune --help 2>/dev/null | grep -q -- '--reserved-space'; then
  MINIMA=(--reserved-space "$CACHE_MINIMA")
else
  MINIMA=(--keep-storage "$CACHE_MINIMA")
fi
if $REAL; then
  docker builder prune -f --filter "until=168h" "${MINIMA[@]}"
else
  echo "  [seco] docker builder prune -f --filter until=168h ${MINIMA[*]}"
  docker system df --format '  {{.Type}}: {{.Size}} ({{.Reclaimable}} recuperable)' | grep -i 'build' || true
fi

echo
echo "== Espacio DESPUES =="
docker system df
echo "== Volumenes: no se tocan nunca =="
