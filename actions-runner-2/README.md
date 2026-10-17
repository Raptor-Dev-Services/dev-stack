# actions-runner-2

Los mismos runners de [`../actions-runner`](../actions-runner/README.md) (imagen oficial, socket de Docker,
home del host en su misma ruta, registro una sola vez), pero **partidos en dos maquinas por
responsabilidad**:

| Compose | Runners | Maquina | Que hace | Etiqueta |
|---|---|---|---|---|
| `compose-build.yaml` | 8 (`<prefijo>-build-1..8`) | la potente | checkout, build, pruebas, `docker build` y **push a Harbor** | `build` |
| `compose-staging.yaml` | 4 (`<prefijo>-staging-1..4`) | el server de staging | **pull de Harbor**, migraciones y `docker compose up` | `staging` |

La de build compila y publica; la de staging nunca compila, solo baja la imagen ya construida y la
levanta. Asi el CPU del server de staging queda para las APIs, la base y el monitoreo.

El detalle de como funciona cada pieza (identidad, rutas, plugin de compose, token) es el mismo y esta en el
README de `../actions-runner`; aqui solo lo que cambia.

## Arrancar

En **cada** maquina, solo su compose, con su propio `.env`:

```sh
cd ~/Docker/dev-stack/actions-runner-2
cp .env.example .env      # RUNNER_TOKEN, RUNNER_NAME_PREFIX (el nombre de ESA maquina) y los ids del host

docker compose -f compose-build.yaml up -d     # en la maquina potente
docker compose -f compose-staging.yaml up -d   # en el server de staging
```

Cada uno tiene su propio nombre de proyecto de compose (`actions-runner-build` y `actions-runner-staging`),
asi que no se pisan entre si ni con los de `../actions-runner`.

## La etiqueta de rol

Cada compose fija `RUNNER_ROLE` (`build` o `staging`) y `entrypoint.sh` la agrega a las etiquetas al
registrar, antes de las de `RUNNER_LABELS`. No va en el `.env` a proposito: si se equivocara, una maquina
de build aceptaria deploys.

- **Las etiquetas se fijan al registrar.** Un runner ya registrado no las cambia al reiniciar: para
  cambiarlas, borra su `RUNNERS_DIR/<nombre>/state` y levantalo con token nuevo.
- **La separacion la hacen los pipelines, no estos runners.** Mientras un job pida solo
  `runs-on: [self-hosted, linux]`, lo puede tomar CUALQUIER runner, de build o de staging. Para que la
  division sirva, cada pipeline tiene que pedir el rol:

  ```yaml
  build-and-push:
    runs-on: [self-hosted, linux, build]
  deploy-staging:
    runs-on: [self-hosted, linux, staging]
  ```

  GitHub no valida etiquetas: un `runs-on` con una etiqueta que ningun runner tiene no falla, se queda en
  cola esperando. Si un job no arranca, revisa eso primero.

## Que necesita cada maquina en `$HOME`

| | build | staging |
|---|---|---|
| `docker login` a Harbor (`~/.docker/config.json`) | si, con permiso de **push** | si, basta **pull** |
| dev-stack (`~/Docker/dev-stack`) y los `.env` de staging | no | si |
| plugin de compose del host (`DOCKER_COMPOSE_PLUGIN`) | se monta igual (pruebas de integracion) | si, imprescindible |

## CPU en la maquina de build: sin limite

Decision del 2026-10-15: **en la maquina de build los builds usan todo el CPU.** Ni el compose ni los
runners ponen limite (no hay `cpus:` ni `mem_limit`), y los jobs de build, al pedir la etiqueta `build`,
deben quitar el `-m:3` de `dotnet build/test` (sin `-m`, MSBuild usa un proceso por hilo). El `-m:3` sigue
haciendo falta en `../actions-runner`, donde los builds comparten la maquina con staging.

- `-nodeReuse:false` **se queda**: no limita CPU, evita que los MSBuild se queden vivos ocupando RAM.
- Con 8 builds a la vez sin limite, cada uno abre un MSBuild por hilo y el CPU queda al 100%. En esta
  maquina no estorba a nadie: no corre staging. Lo que puede faltar antes es **RAM**; si se ve swap, bajar
  runners o volver a poner `-m`.
- El build de Android trae su propio tope en el pipeline (`--cpus 8 --memory 12g`, 6 workers de Gradle);
  para quitarlo tambien hay que tocar ese pipeline.

**La GPU no sirve para compilar.** Compilar (.NET, Node, Gradle, `docker build`) es trabajo de CPU, disco y
RAM: ninguno de esos compiladores sabe usar una GPU, y no hay forma de hacer que la usen. La RTX de la
maquina queda libre para otras cosas (modelos locales, transcodificar video), no para el CI.

## Hardware (2026-10-15)

| | Server actual (v1 + staging) | VM de build |
|---|---|---|
| Equipo | ThinkCentre M90q Gen 2, Ubuntu 26.04 | VM KVM en Proxmox VE 9.2, Ubuntu 26.04 |
| CPU | i5-11500, 6 nucleos / 12 hilos | Ryzen 5 3600, 6 nucleos / 12 hilos (todos a la VM) |
| RAM | 30.5 GB | 27 GB (el host Proxmox tiene 31 GB y ya va al 81%) |
| Disco | 231 GB NVMe + 109 GB SATA para CI | 687 GB |

Lo que eso significa:

- **La VM no es mas potente que el server**: mismos 12 hilos, y por nucleo el i5-11500 rinde igual o un
  poco mas que el Ryzen 5 3600. Lo que gana partir en dos maquinas es **aislamiento** (staging deja de
  sufrir los builds), no builds mas rapidos.
- **En la VM el limite es la RAM, no el CPU.** 27 GB entre 8 builds sin `-m` da ~3.4 GB por build, y un
  job de Android pide 12 GB solo. Si coinciden, swap (4 GB) y OOM: builds que mueren sin razon aparente.
  La primera vez que coincidan varios, mirar `free -h`, `btop` y `dmesg | grep -i oom`; si hay swap u OOM,
  `-m:4` o menos runners.
- **Mas runners no suman CPU.** 8 sirven para que los jobs ligeros no hagan cola detras de un build, no para
  compilar mas rapido. Por lo mismo, el server actual se queda con 4 y `-m:3`: con 8 la regla daria `-m:1`
  o volveria la saturacion medida el 2026-10-01, y ahi tambien corre staging.
- **En Proxmox, tipo de CPU `host`** para la VM (Hardware > Processors > Type), no el generico `kvm64` /
  `x86-64-v2`: con el generico la VM no ve todas las instrucciones del Ryzen.
- **`RUNNER_NAME_PREFIX=arccnova`** en la VM: su hostname es `arccnova-stagin`, pero hace builds; asi los
  runners salen como `arccnova-build-1..8` y no confunden.
- La GPU del host (RTX 2080 Ti) no esta pasada a la VM, y aunque lo estuviera no sirve para compilar.

## Limpieza diaria de las carpetas de trabajo

`mantenimiento/limpiar-runners.sh` de esta carpeta es la de `../mantenimiento/limpiar-runners.sh`
adaptada: busca los contenedores de los proyectos `actions-runner-build` y `actions-runner-staging`, y
**no toca** los de `../actions-runner`. Mismo comportamiento: a las 05:00 de Ciudad de Mexico, runner libre
se detiene, se vacia su `_work` y se arranca; runner ocupado se reintenta cada 10 min hasta 6 veces;
`state/` no se toca nunca.

Se instala **en cada maquina** (build y staging), desde la copia del repo que se queda en ella:

```sh
sudo sh actions-runner-2/mantenimiento/instalar-limpiar-runners.sh
bash actions-runner-2/mantenimiento/limpiar-runners.sh --seco          # probar sin borrar
sudo systemctl start --no-block limpiar-runners-2.service              # correrla ya
journalctl -u limpiar-runners-2.service -f                             # ver lo que hizo
```

- La unidad se llama `limpiar-runners-2` para convivir con la de v1 si una maquina tiene las dos.
- El `.service` del repo es plantilla: el instalador pone el usuario que corre `sudo` y la ruta real de la
  carpeta, porque la maquina de build no tiene por que tener el mismo usuario ni el repo en
  `~/Docker/dev-stack`.
- Probado el 2026-10-15 con contenedores falsos: vacia los de build y staging, respeta el que tiene un
  `Runner.Worker` vivo y deja intactos los del proyecto `actions-runner`. Contra runners reales todavia no.

## Relacion con `../actions-runner`

`../actions-runner` es la **v1, para cuando hay un solo nodo** (4 runners iguales que hacen todo) y se queda
como esta. Esta carpeta es para cuando hay dos maquinas. Mientras convivan, los jobs que no pidan rol los
puede tomar cualquiera de los tres grupos.

`../mantenimiento/limpiar-docker.sh` (imagenes y cache de build) y el segundo disco siguen escritos para la
v1; no se han adaptado a estos.
