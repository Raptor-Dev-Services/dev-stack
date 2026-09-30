# actions-runner

Runners self-hosted de GitHub Actions **en contenedores**, sobre la imagen oficial
(`ghcr.io/actions/actions-runner`). Reemplazan al runner instalado directo en el server: en vez de uno,
**N runners iguales** que se reparten los jobs, cada uno capaz de correr cualquier pipeline.

Vive dentro de `dev-stack` pero **se levanta aparte**: tiene su propio `compose.yaml` y su propio `.env`.

## Por que la imagen oficial y no una propia

Los pipelines ya corren cada paso en un contenedor (`docker run mcr.microsoft.com/dotnet/sdk:10.0`,
`node:22`, `python:3-slim`) contra el Docker del host. El runner solo necesita saber llamar a Docker, y la
oficial ya trae el CLI. Asi:

- cada repo fija sus propias versiones de toolchain en su `pipeline.yml`;
- estos runners sirven para cualquier proyecto sin tocarlos;
- no hay imagen propia que construir, versionar ni parchar.

La excepcion futura seria Android (Android SDK + Gradle no caben bien en un `docker run` por paso): si
llega, se agrega un runner con imagen propia y su etiqueta, solo para eso.

## Arrancar

```sh
cd ~/Docker/dev-stack/actions-runner
cp .env.example .env
# En .env: RUNNER_TOKEN, y los ids del host (id -u, id -g, getent group docker | cut -d: -f3)
docker compose up -d
docker compose logs -f        # "registrado; credenciales guardadas en ..." y luego "Listening for Jobs"
```

El token de registro sale de GitHub: organizacion > Settings > Actions > Runners > **New self-hosted
runner** (el valor despues de `--token`). **Caduca en una hora** y solo se usa en el primer arranque de
cada runner; despues se puede vaciar en el `.env`.

Los runners aparecen en GitHub como `<RUNNER_NAME_PREFIX>-1`, `-2`, ... con las etiquetas
`self-hosted, Linux, X64` (las que piden hoy los pipelines) mas las de `RUNNER_LABELS`.

## Agregar o quitar runners

- **Agregar:** copia el bloque `runner-2` de `compose.yaml` como `runner-3` y cambia el numero en sus tres
  lineas. Genera un token nuevo si ya caduco el anterior y `docker compose up -d`.
- **Quitar:** `docker compose rm -sf runner-N`, borra su carpeta `RUNNERS_DIR/<nombre>` y quitalo en
  GitHub (Settings > Actions > Runners).

Cada runner se declara aparte, y no con `deploy.replicas`, porque cada uno guarda sus credenciales en su
propia carpeta de estado: con replicas compartirian nombre y credenciales.

Cuantos: en el Pentium J5005 del server actual, **2**. No suman CPU, pero la API y el panel dejan de
esperarse uno al otro y los jobs ligeros (secretos, dependencias) no hacen cola detras de un build. En una
maquina de 4 nucleos/8 hilos o mas, 3.

## Como funciona (y por que asi)

`entrypoint.sh` arranca como root solo para preparar; el runner corre como usuario normal:

1. **Identidad.** En la imagen, `runner` es uid 1001 y su grupo `docker` es gid 123. Se remapean al
   usuario del host (`RUNNER_UID`/`RUNNER_GID`) y al grupo docker del host (`DOCKER_GID`). Sin eso el
   socket de Docker rechaza al runner, los `docker run -u $(id -u)` de los pipelines dejan archivos de otro
   usuario, y el runner no puede leer `~/.docker/config.json` (login de Harbor) ni los `.env` de staging.
2. **Mismo `$HOME` y mismas rutas que el host.** El home del host se monta **en su misma ruta** y es el
   `HOME` del runner. Los pipelines hacen `docker run -v "$PWD":/src`, y ese `$PWD` lo resuelve el Docker
   del **host**: si la ruta no existiera igual afuera, el build veria una carpeta vacia. Por eso
   `RUNNERS_DIR` tiene que vivir dentro de `HOST_HOME`.
3. **Registro una sola vez.** Con token, registra y copia sus credenciales a
   `RUNNERS_DIR/<nombre>/state`. En cada arranque siguiente las restaura y no pide token.

Probado en local (2026-09-30): sin token para con el mensaje de arriba; con un token falso llega a GitHub y
es rechazado (404); la identidad queda `uid=1000(runner)` con el grupo `docker` del host y `HOME` en el home
del host. **El registro real y un job real no se han probado todavia**: eso pasa en el server.

## Cuidado

- **El socket de Docker equivale a root en el host.** Es el mismo nivel de confianza que tenia el runner
  instalado directo; estos runners solo deben atender repos propios de la organizacion.
- **Un runner que pase 14 dias apagado** se da de baja en GitHub: al volver necesita token nuevo (borra su
  carpeta `state` y levantalo con token).
- **Varios runners pueden desplegar a la vez.** Los jobs de deploy a staging tienen que declarar su grupo
  de `concurrency` para ir en fila (los de SocioFit ya lo hacen).
- **`../bajar-todo.sh` los para** (detiene todo contenedor que siga corriendo), y con
  `restart: unless-stopped` no vuelven solos: `docker compose up -d` aqui despues de usarlo.
- **El runner viejo del host** (`~/actions-runner`, servicio de systemd) sigue registrado aparte. Apagalo
  cuando estos esten probados, y despues quitalo en GitHub.
