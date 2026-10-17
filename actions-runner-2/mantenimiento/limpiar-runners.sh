#!/usr/bin/env bash
# =============================================================================
# limpiar-runners.sh - Vacia cada noche las carpetas de trabajo de los runners de actions-runner-2
# Adaptado el 2026-10-15 de ../../mantenimiento/limpiar-runners.sh, que solo ve los de ../../actions-runner.
# =============================================================================
# Cada runner guarda en RUNNERS_DIR/<runner>/_work los checkouts, las herramientas y los artefactos de sus
# jobs. El checkout limpia el codigo, pero lo demas se queda y crece: el 2026-10-15 eran 36 GB. Este script
# lo vacia runner por runner, y nada mas:
#
#   1. Encuentra los runners por la etiqueta de compose (proyectos `actions-runner-build` y
#      `actions-runner-staging`: en cada maquina corre uno de los dos); de cada contenedor saca
#      RUNNER_NAME y RUNNERS_DIR, asi que no lee el .env (que tiene el token).
#   2. Si el runner tiene un job corriendo (proceso Runner.Worker), NO lo toca y lo reintenta despues.
#   3. Si esta libre: lo detiene, vacia su _work y lo vuelve a arrancar. Detenerlo primero evita que tome un
#      job a media limpieza. `state/` (sus credenciales) no se toca nunca.
#   4. Los runners que seguian ocupados se reintentan cada ESPERA segundos, hasta INTENTOS veces; si alguno
#      sigue ocupado al final, se queda para la noche siguiente.
#
# Se borra con un contenedor efimero (alpine) y no con `rm` directo: los builds corren en `docker run` y a
# veces dejan archivos de root que el usuario normal no puede borrar.
#
# Lo dispara limpiar-runners-2.timer todos los dias a las 05:00 de Ciudad de Mexico. Instalacion, una vez
# en CADA maquina (la de build y la de staging):
#     sudo sh actions-runner-2/mantenimiento/instalar-limpiar-runners.sh
#
# Uso a mano:
#   bash actions-runner-2/mantenimiento/limpiar-runners.sh --seco   # dice que haria, sin detener ni borrar
#   bash actions-runner-2/mantenimiento/limpiar-runners.sh          # limpia
# Variables (opcionales): ESPERA (default 600 s), INTENTOS (default 6).
# =============================================================================
set -euo pipefail

SECO=false
[ "${1:-}" = "--seco" ] && SECO=true
ESPERA="${ESPERA:-600}"
INTENTOS="${INTENTOS:-6}"
IMAGEN=alpine:latest
# Los dos proyectos de compose de actions-runner-2. Se consulta uno por uno: en `docker ps` varios filtros
# `label` se combinan con Y, no con O, y juntos no encontrarian ningun contenedor (medido el 2026-10-15).
PROYECTOS=(actions-runner-build actions-runner-staging)
runners() { for p in "${PROYECTOS[@]}"; do docker ps --filter "label=com.docker.compose.project=$p" "$@"; done; }

entorno() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n "s/^$2=//p"; }
# Por el codigo de salida de grep, no por su conteo: `grep -c` sin coincidencias imprime 0 Y sale con 1, y un
# `|| echo 0` detras dejaba "0\n0", que nunca era igual a "0": todo runner libre parecia ocupado (2026-10-15).
ocupado() { docker exec "$1" sh -c 'ps -eo args | grep -q "[R]unner.Worker"' 2>/dev/null; }

# Si algo falla a media limpieza, el runner que se detuvo vuelve a arrancar igual.
DETENIDO=""
trap '[ -n "$DETENIDO" ] && docker start "$DETENIDO" >/dev/null' EXIT

limpiar() {
  local c=$1 nombre dir work antes
  nombre=$(entorno "$c" RUNNER_NAME); dir=$(entorno "$c" RUNNERS_DIR)
  work="$dir/$nombre/_work"
  if [ -z "$nombre" ] || [ -z "$dir" ] || [ ! -d "$work" ]; then
    echo "  $c: sin carpeta de trabajo ($work); nada que hacer"; return 0
  fi
  antes=$(du -sh "$work" 2>/dev/null | cut -f1)
  if $SECO; then echo "  [seco] $c: detendria, vaciaria $work ($antes) y lo arrancaria"; return 0; fi
  DETENIDO=$c
  docker stop "$c" >/dev/null
  docker run --rm -v "$work":/w "$IMAGEN" find /w -mindepth 1 -delete
  docker start "$c" >/dev/null
  DETENIDO=""
  echo "  $c: $work vaciada ($antes liberados)"
}

echo "== Limpieza de runners: $($SECO && echo 'EN SECO' || echo 'REAL') - $(date '+%F %T %Z') =="
mapfile -t PENDIENTES < <(runners --format '{{.Names}}' | sort)
[ ${#PENDIENTES[@]} -gt 0 ] || { echo "No hay runners corriendo; nada que limpiar."; exit 0; }
docker image inspect "$IMAGEN" >/dev/null 2>&1 || docker pull -q "$IMAGEN" >/dev/null

for ((i = 1; i <= INTENTOS; i++)); do
  OCUPADOS=()
  for c in "${PENDIENTES[@]}"; do
    if ocupado "$c"; then OCUPADOS+=("$c"); echo "  $c: tiene un job corriendo; se reintenta"; else limpiar "$c"; fi
  done
  [ ${#OCUPADOS[@]} -eq 0 ] && break
  PENDIENTES=("${OCUPADOS[@]}")
  if [ "$i" -lt "$INTENTOS" ] && ! $SECO; then sleep "$ESPERA"; else break; fi
done

[ ${#OCUPADOS[@]} -eq 0 ] || echo "Siguieron ocupados, quedan para la proxima: ${OCUPADOS[*]}"
echo "== Disco de los runners =="
df -h "$(entorno "$(runners -q | head -1)" RUNNERS_DIR)"
