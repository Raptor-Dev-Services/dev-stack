# dev-stack

La infraestructura de desarrollo y staging que comparten varios productos en un mismo servidor: **un solo**
Postgres, MinIO, Redis y Mailpit, con una base y un rol dueno por producto, mas el monitoreo y los runners
de GitHub Actions. Cada pieza se levanta por su lado:

| Carpeta | Que es | Se levanta con |
|---|---|---|
| [`stack/`](stack/README.md) | La infraestructura: Postgres, MinIO, Redis, Mailpit y el monitoreo (Seq, Prometheus, Grafana, Uptime Kuma, node-exporter, Dashy), con su configuracion y su documentacion | `cd stack && docker compose -f compose-dev.yaml up -d` |
| [`actions-runner/`](actions-runner/README.md) | Runners self-hosted de GitHub Actions, en contenedores | `cd actions-runner && docker compose up -d` |
| [`actions-runner-2/`](actions-runner-2/README.md) | Los mismos runners partidos en dos maquinas: una compila y publica, la otra solo despliega | ver su README |
| [`mantenimiento/`](mantenimiento/) | Limpieza diaria de Docker y de los runners, y un script para mover lo regenerable a un segundo disco | ver la cabecera de cada script |

Del stack hay ademas [`stack/MONITOREO.md`](stack/MONITOREO.md) (Grafana, Prometheus, node-exporter) y
[`stack/PUERTOS.md`](stack/PUERTOS.md) (el mapa de puertos y las trampas de cada uno).

## Como se usa

1. Clona este repo en el servidor (p. ej. en `~/Docker/dev-stack`).
2. En `stack/`, copia `.env.example` a `.env` y llenalo. **No trae ningun puerto ni credencial por
   omision**: compose se niega a arrancar si falta una variable, a proposito.
3. Declara tus productos en `stack/productos.conf` (copia de `productos.conf.example`): cada uno recibe su
   base, su rol dueno, su rol de aplicacion sin DDL y su bucket.
4. `docker compose -f compose-dev.yaml up -d`.
5. Si vas a usar runners propios: `actions-runner/`, con su propio `.env`.

Lo que este repo **no** versiona: los `.env`, `productos.conf`, las licencias y `stack/data/`. Eso vive solo
en el servidor; respaldalo aparte.

Las carpetas de los runners y las caches de paquetes pueden vivir en un segundo disco montado con bind
mounts: [`actions-runner/README.md`](actions-runner/README.md#segundo-disco-para-lo-regenerable).
