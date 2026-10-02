# Mapa de puertos del stack de desarrollo

Una sola tabla para toda la maquina. Antes de asignar un puerto nuevo, mirala: varios
choques de puerto **no dan error**, que es lo que los hace caros.

Este archivo es la plantilla. El mapa real de tu maquina, con los nombres de tus productos,
va en **`PUERTOS.local.md`**, que no se versiona.

## Infraestructura compartida

| Servicio | Puerto | Se abre en |
|---|---|---|
| PostgreSQL 17 | `5432` | — |
| MinIO (API) | `9000` | — |
| MinIO (consola) | `9001` | http://localhost:9001 |
| Redis | `6379` | — |
| Mailpit (SMTP) | `1025` | — |
| Mailpit (bandeja) | `8025` | http://localhost:8025 |
| Seq (ingesta de logs) | `5341` | — (solo recibe; es el `Seq__ServerUrl` de los productos) |
| Seq (interfaz) | `5380` | http://localhost:5380 |
| Prometheus | `9090` | http://localhost:9090 (receptor OTLP en `/api/v1/otlp/v1/metrics`) |
| Grafana | `3000` | http://localhost:3000 |
| Uptime Kuma | `3001` | http://localhost:3001 |
| Dashy | `4000` | http://localhost:4000 (un link a todo lo demas) |
| docker-socket-proxy | *(ninguno)* | no se publica: Uptime Kuma lo usa como `http://docker-socket-proxy:2375` (solo lectura de contenedores) |
| node-exporter | *(ninguno)* | no se publica: Prometheus lo lee como `node-exporter:9100` dentro de la red `devstack` |

Todos se publican en la direccion `DEVSTACK_BIND` del `.env`: `127.0.0.1` los deja solo para
esta maquina.

Son los valores de `.env.example`; el que manda es tu `.env`, que es obligatorio. Las
credenciales de administracion tambien salen de ahi: `postgres` / `postgres` y
`minioadmin` / `minioadmin` por omision en el ejemplo, y las de Seq y Grafana las eliges tu.
Son de desarrollo local.

## APIs

El mismo puerto en los dos modos —`dotnet run` y contenedor— para que los `.env` de los
webclient y de las apps moviles valgan igual en ambos.

| Producto | Puerto | Base de datos | Rol de la app | Vida | Disponibilidad |
|---|---|---|---|---|---|
| `{{PRODUCTO_A}}` | `{{API_PORT_A}}` | `{{DB_PRODUCTO_A}}` | `{{PRODUCTO_A}}_owner` | `/health/live` | `/health/ready` |
| `{{PRODUCTO_B}}` | `{{API_PORT_B}}` | `{{DB_PRODUCTO_B}}` | `{{PRODUCTO_B}}_app` | `/health/live` | `/health/ready` |

**No asumas una ruta de salud comun.** Si escribes algo que compruebe todos a la vez, apunta
la ruta de cada uno: sondearlos con la misma deja fuera a los que la exponen distinto (bajo
`/api/v1/`, como controlador en vez de `MapHealthChecks`...), y un `grep MapHealthChecks`
vacio se lee como "no tiene sonda" cuando si la tiene.

**Un `/health` que contesta no dice que la base este viva.** Las sondas de vida no deben
tocar Postgres; para saber si el sistema sirve peticiones, usa la de disponibilidad.

## Web clients (Vite)

| Producto | Puerto | Por que ese |
|---|---|---|
| `{{PRODUCTO_A}}` | `5173` | `{{MOTIVO}}` (p. ej. un callback de login exacto que no se puede mover) |
| `{{PRODUCTO_B}}` | `5174` | `strictPort`, para que no salte en silencio a otro |

Usa `strictPort: true` en todos: sin el, Vite toma el siguiente puerto libre y el front
queda donde nadie lo busca.

## Staging en `raptor-server` (el servidor propio)

Esta tabla es **del servidor**, no de tu maquina. Ahi conviven los productos desplegados por sus
pipelines, Harbor y el dev-stack. Antes de asignarle un puerto a un producto nuevo, mirala y
**reserva el tuyo aqui en el mismo commit**: hay varios agentes trabajando en paralelo y el que no
reserva, choca.

| Puerto | Quien | Contenedor |
|---|---|---|
| `8080` | C-MSA API | `cmsa-api-staging` *(solo EXPOSE, no publicado)* |
| `8081` | **SocioFit API** | `sociofit-api-staging` **(host mode: NO sale en `docker ps`)** |
| `8082` | SocioFit panel | `sociofit-web-staging` |
| `8083` | **SocioRent API** | `sociorent-api-staging` **(host mode: NO sale en `docker ps`)** |
| `8084` | C-MSA panel | `cmsa-front-staging` |
| `8085` | **SocioRent panel** | `sociorent-web-staging` |
| `8086` | Pagina de Raptor | `raptor-page` |
| `8088` | Harbor | `nginx` (puerta local) |

**Libres hoy:** `8087`, `8089`, y el rango `8090`-`8099`.

### La trampa: `docker ps` NO muestra todos los puertos ocupados

Un contenedor con `network_mode: host` **comparte la red del host y su columna PORTS sale vacia**.
`sociofit-api-staging` lleva asi desde el principio: ocupa el 8081 y en `docker ps` no aparece ni una
sola vez. Lo mismo vale para la API de SocioRent en el 8083.

Si eliges puerto mirando solo `docker ps`, vas a tomar uno ocupado y el choque **no da un error
claro**: segun quien arranque primero, uno de los dos queda sin atender o contesta el equivocado.
Para ver lo que de verdad escucha en el servidor:

```sh
ss -ltnp | sort -t: -k2 -n     # o: sudo lsof -nP -iTCP -sTCP:LISTEN
```

### Hostnames publicos (tunel de Cloudflare)

**Solo salen la API y el panel de cada producto**, mas el `9000` de MinIO. Nada mas: el resto de la
infraestructura la publica el dev-stack atada a `127.0.0.1` y es inalcanzable desde fuera. Exponer el
`5432` abriria la base de **todos** los productos a la vez.

El `9000` es la excepcion que parece un descuido y no lo es: los enlaces de archivos se **firman** con
ese host, y la firma incluye el host, asi que no se puede reescribir despues. Si se firmaran con
`127.0.0.1`, el navegador no resuelve esa direccion y todo adjunto se ve roto mientras la API responde
200.

De **un solo nivel**: el certificado gratuito cubre `*.raptorcloud.dev`, no `producto.api.raptorcloud.dev`.

| Hostname | Apunta a |
|---|---|
| `sociofit-api.raptorcloud.dev` | `localhost:8081` |
| `sociofit-app.raptorcloud.dev` | `localhost:8082` |
| `sociorent-api.raptorcloud.dev` | `localhost:8083` |
| `sociorent-app.raptorcloud.dev` | `localhost:8085` |
| `files.raptorcloud.dev` | `localhost:9000` (MinIO, compartido por todos) |
| `harbor.raptorcloud.dev` | Harbor |


## Puertos que NO se pueden usar en macOS

| Puerto | Quien lo tiene | Sintoma |
|---|---|---|
| `5000` | AirPlay Receiver | `403` a todo con `Server: AirTunes`. Se apaga en Ajustes -> General -> AirDrop y Handoff |
| `7000` | AirPlay Receiver | Igual |

## Bases logicas de Redis

**No es un aislamiento de verdad** —`FLUSHALL` las borra todas— pero basta en desarrollo.

| Base | Producto |
|---|---|
| `0` | `{{PRODUCTO_A}}` |
| `1` | `{{PRODUCTO_B}}` |

## Buckets de MinIO

Salen de la ultima columna de `productos.conf`. Todos **privados**; las lecturas se sirven
con URLs prefirmadas de vida corta.

## `localhost` y `127.0.0.1` pueden ser servidores DISTINTOS

Un proceso atado a `0.0.0.0` (IPv4) y otro a `[::1]` (IPv6) **conviven en el mismo puerto
sin que ninguno falle**. En macOS `localhost` resuelve primero a IPv6, asi que
`curl localhost:<puerto>` y `curl 127.0.0.1:<puerto>` pueden contestar procesos diferentes.

Para .NET (Kestrel) la regla es la contraria de lo que parece:

| `--urls` | sockets que abre | `127.0.0.1` | `[::1]` |
|---|---|---|---|
| `http://localhost:<puerto>` | IPv4 **y** IPv6 | 200 | 200 |
| `http://127.0.0.1:<puerto>` | **solo IPv4** | 200 | **inalcanzable** |
| `http://+:<puerto>` | IPv6 dual-stack | 200 | 200 |

**Para una API .NET: `localhost` o `+`, nunca `127.0.0.1`**, que deja `[::1]` libre para que
otro proceso lo tome en silencio. Node y Vite atan una sola familia: hay que decirles
explicitamente que escuchen en las dos.

Para ver quien tiene un puerto, en las dos familias:

```sh
lsof -nP -iTCP:<puerto> -sTCP:LISTEN
```
