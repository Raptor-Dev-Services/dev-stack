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

- **Agregar:** copia el bloque `runner-4` de `compose.yaml` como `runner-5` y cambia el numero en sus tres
  lineas. Genera un token nuevo si ya caduco el anterior y `docker compose up -d`.
- **Quitar:** `docker compose rm -sf runner-N`, borra su carpeta `RUNNERS_DIR/<nombre>` y quitalo en
  GitHub (Settings > Actions > Runners).

Cada runner se declara aparte, y no con `deploy.replicas`, porque cada uno guarda sus credenciales en su
propia carpeta de estado: con replicas compartirian nombre y credenciales.

El compose trae **4**. En una maquina chica se pueden levantar solo algunos
(`docker compose up -d runner-1 runner-2`): en el Pentium J5005 del server actual, 4 builds de .NET a la vez
se reparten 4 nucleos lentos y cada uno tarda mas, asi que ahi conviene 2. Mas runners no suman CPU; lo
que ganan es que los jobs ligeros (secretos, dependencias) y los de otro repo no hacen cola detras de un
build.

## Varias maquinas

El mismo compose sirve en cada PC que quieras sumar como runner de la organizacion:

- **`RUNNER_NAME_PREFIX` distinto en cada maquina** (su nombre). Si dos usan el mismo, el registro de una
  (`--replace`) le quita los runners a la otra sin avisar.
- **Host Linux.** El truco de montar el home en su misma ruta necesita que el Docker del host vea las
  mismas rutas que el runner. En Windows o macOS con Docker Desktop no se cumple (`C:\Users\...` no existe
  dentro de la VM); ahi tendria que ser dentro de WSL2, con el clon y el home en el sistema de archivos de
  Linux, y no esta probado.
- **Lo que los pipelines esperan en `$HOME`** tiene que existir en esa maquina: `docker login` a Harbor
  para los jobs que empujan imagenes, y para los deploys de staging, el dev-stack y los `.env` de staging.
  Una maquina que solo va a compilar no necesita lo de staging, pero hoy cualquier runner puede recibir un
  deploy: si una maquina no debe desplegar, dale una etiqueta extra (`RUNNER_LABELS`) y haz que el job de
  deploy la pida.

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
3. **Compose del host.** La imagen oficial trae el CLI de Docker pero no el plugin de compose, y los
   deploys hacen `docker compose up`. Se monta el del host (`DOCKER_COMPOSE_PLUGIN`); si la ruta esta mal,
   el runner avisa al arrancar. Sin eso, un deploy llega a empujar la imagen y migrar la base, y falla en el
   ultimo paso con `unknown flag: --env-file` (paso el 2026-09-30).
4. **Registro una sola vez.** Con token, registra y copia sus credenciales a
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
