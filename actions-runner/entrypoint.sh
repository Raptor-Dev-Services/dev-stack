#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh - arranca UN runner de GitHub Actions sobre la imagen oficial
# =============================================================================
# La imagen oficial (ghcr.io/actions/actions-runner) no trae entrypoint: solo el runner y el CLI de
# Docker. Este script hace las tres cosas que faltan, y el contenedor arranca como root SOLO para la
# primera; el runner en si corre como usuario normal.
#
#   1. IDENTIDAD. En la imagen el usuario `runner` es uid 1001 y su grupo `docker` es gid 123, que no
#      coinciden con el host. Se remapean al uid/gid del usuario del host y al gid del grupo docker del
#      host. Sin eso: el socket de Docker rechaza al runner, los `docker run -u $(id -u)` de los
#      pipelines dejan archivos de otro usuario, y el runner no puede leer ~/.docker/config.json ni los
#      .env de staging (0600 del usuario del host).
#   2. REGISTRO. La primera vez se registra con RUNNER_TOKEN y guarda sus credenciales en su carpeta de
#      estado. Las siguientes veces las restaura y NO necesita token: el token de GitHub caduca en una
#      hora, las credenciales no.
#   3. ARRANQUE. `run.sh` como el usuario `runner`, con HOME = el home del host, para que `$HOME/...`
#      en los pipelines apunte a lo mismo que cuando el runner corria directo en el host.
# =============================================================================
set -euo pipefail

falta() { echo "entrypoint: falta la variable $1 (ver actions-runner/.env.example)" >&2; exit 1; }
[ -n "${GITHUB_URL:-}" ]   || falta GITHUB_URL
[ -n "${RUNNER_NAME:-}" ]  || falta RUNNER_NAME
[ -n "${HOST_HOME:-}" ]    || falta HOST_HOME
[ -n "${RUNNERS_DIR:-}" ]  || falta RUNNERS_DIR
[ -n "${RUNNER_UID:-}" ]   || falta RUNNER_UID
[ -n "${RUNNER_GID:-}" ]   || falta RUNNER_GID
[ -n "${DOCKER_GID:-}" ]   || falta DOCKER_GID

# La carpeta de trabajo tiene que existir EN LA MISMA RUTA dentro y fuera del contenedor: los pipelines
# hacen `docker run -v "$PWD":/src`, y ese $PWD lo resuelve el Docker del HOST. Se garantiza montando el
# home del host en su misma ruta, asi que RUNNERS_DIR tiene que vivir dentro de el.
case "$RUNNERS_DIR" in
  "$HOST_HOME"/*) ;;
  *) echo "entrypoint: RUNNERS_DIR ($RUNNERS_DIR) debe estar dentro de HOST_HOME ($HOST_HOME)." >&2; exit 1 ;;
esac

ROOT=/home/runner
# `runuser` no cambia HOME: sin esto el runner veria /root y `$HOME/...` de los pipelines apuntaria a
# ninguna parte.
export HOME="$HOST_HOME"
STATE="$RUNNERS_DIR/$RUNNER_NAME/state"
WORK="$RUNNERS_DIR/$RUNNER_NAME/_work"

# --- 1. Identidad --------------------------------------------------------------------------------
# La base Ubuntu 24.04 trae un usuario `ubuntu` con uid/gid 1000, justo el del primer usuario de casi
# cualquier host: si se deja, el runner aparece como `ubuntu` en `id`, en los logs y en los archivos. Se
# quita cuando choca. -o en lo demas: permite un id que la imagen ya use para otra cosa.
if id ubuntu >/dev/null 2>&1 && { [ "$(id -u ubuntu)" = "$RUNNER_UID" ] || [ "$(id -g ubuntu)" = "$RUNNER_GID" ]; }; then
  userdel ubuntu >/dev/null 2>&1 || true
  groupdel ubuntu >/dev/null 2>&1 || true
fi
groupmod -o -g "$RUNNER_GID" runner
usermod -o -u "$RUNNER_UID" -g "$RUNNER_GID" -d "$HOST_HOME" runner
groupmod -o -g "$DOCKER_GID" docker
# Los binarios del runner siguen siendo del uid viejo; solo se corrige la primera vez que arranca este
# contenedor (en un reinicio ya estan bien y chown -R sobre todo el runner es lento en maquinas chicas).
if [ "$(stat -c %u "$ROOT")" != "$RUNNER_UID" ]; then
  chown -R runner:runner "$ROOT"
fi
# Las carpetas del runner se crean como root y se le entregan (RUNNERS_DIR puede no existir todavia);
# el home del host no se toca.
mkdir -p "$STATE" "$WORK"
chown "$RUNNER_UID:$RUNNER_GID" "$RUNNERS_DIR" "$RUNNERS_DIR/$RUNNER_NAME" "$STATE" "$WORK"

# --- 2. Registro ---------------------------------------------------------------------------------
if [ -f "$STATE/.runner" ]; then
  echo "entrypoint: $RUNNER_NAME ya estaba registrado; se restauran sus credenciales."
  cp -a "$STATE"/.runner "$STATE"/.credentials* "$ROOT"/
else
  if [ -z "${RUNNER_TOKEN:-}" ]; then
    echo "entrypoint: $RUNNER_NAME no esta registrado y RUNNER_TOKEN esta vacio." >&2
    echo "  Genera un token en GitHub (org > Settings > Actions > Runners > New runner), ponlo en" >&2
    echo "  actions-runner/.env y vuelve a levantar. Caduca en una hora; despues se puede borrar." >&2
    exit 1
  fi
  ARGS=(--unattended --replace
        --url "$GITHUB_URL" --token "$RUNNER_TOKEN"
        --name "$RUNNER_NAME" --work "$WORK"
        --runnergroup "${RUNNER_GROUP:-Default}")
  # Las etiquetas base (self-hosted, Linux, X64) las pone el runner solo; estas son extra.
  if [ -n "${RUNNER_LABELS:-}" ]; then ARGS+=(--labels "$RUNNER_LABELS"); fi
  echo "entrypoint: registrando $RUNNER_NAME en $GITHUB_URL ..."
  runuser -u runner -- "$ROOT/config.sh" "${ARGS[@]}"
  cp -a "$ROOT"/.runner "$ROOT"/.credentials* "$STATE"/
  echo "entrypoint: registrado; credenciales guardadas en $STATE."
fi

# --- 3. Arranque ---------------------------------------------------------------------------------
cd "$ROOT"
exec runuser -u runner -- "$ROOT/run.sh"
