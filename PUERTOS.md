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
