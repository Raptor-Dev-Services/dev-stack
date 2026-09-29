# Monitoreo: las carpetas de Grafana y Prometheus

Como estan armadas, que se versiona y que no, y lo que hay que hacer **antes del primer
arranque en un servidor Linux** para que no fallen por permisos.

El resumen de que es cada pieza y como se conecta un producto esta en el `README.md`, seccion
*Monitoreo*. Este documento es la parte operativa.

---

## Dos tipos de carpeta, y no se mezclan

| Carpeta | Que tiene | Se versiona | Se monta |
|---|---|---|---|
| `prometheus/` | `prometheus.yml`, la configuracion | **si** | solo lectura, en `/etc/prometheus` |
| `grafana/provisioning/` | lo que Grafana crea solo al arrancar: fuentes de datos y tableros | **si** | solo lectura, en `/etc/grafana/provisioning` |
| `data/prometheus/` | la base de series de tiempo (TSDB) | no | lectura y escritura, en `/prometheus` |
| `data/grafana/` | `grafana.db` (usuarios, tableros creados a mano, preferencias) y plugins | no | lectura y escritura, en `/var/lib/grafana` |

La regla que sale de la tabla: **lo que un clon limpio debe traer va en `prometheus/` o en
`grafana/provisioning/`; lo que se genera al usar el stack cae en `data/`**. Si configuras algo
a mano en la interfaz de Grafana, vive solo en `data/grafana/grafana.db` y no viaja al servidor.

---

## Primer arranque en un servidor Linux: los permisos

En Windows y en macOS (Docker Desktop) no hace falta nada: el puente de archivos no aplica
los permisos de Linux. **En un servidor Linux si**, y el fallo no es obvio.

Cada imagen corre con un usuario propio, no con root:

| Servicio | Usuario dentro del contenedor | UID:GID |
|---|---|---|
| Grafana | `grafana` | `472:0` |
| Prometheus | `nobody` | `65534:65534` |
| Seq | root | no requiere nada |
| Uptime Kuma | root | no requiere nada |

Si `data/grafana` o `data/prometheus` no existen, Docker las crea **como root** al primer `up`, y
ninguno de los dos puede escribir en ellas:

- Prometheus sale con `permission denied` sobre `queries.active`, queda `unhealthy`, y el `up`
  termina en `dependency failed to start: container devstack-prometheus is unhealthy`.
- Grafana ni arranca: depende de Prometheus. Si arrancara, fallaria igual con
  `GF_PATHS_DATA='/var/lib/grafana' is not writable`.

**Ya no hay que hacer nada a mano.** El servicio `permisos-init` del compose corre en cada `up`,
crea las carpetas de `data/` y les pone el dueno correcto; Prometheus y Grafana esperan a que
termine. Se ve en `docker logs devstack-permisos-init` (`==> permisos de data/ listos`) y queda
como `Exited (0)`, que es lo correcto.

Si alguna vez falla -por ejemplo, `data/` en un sistema de archivos que no admite `chown`, como
un recurso compartido de red-, el arreglo manual es el mismo que hace el servicio:

```sh
sudo chown -R 472:0         data/grafana
sudo chown -R 65534:65534   data/prometheus
docker compose -f compose-dev.yaml up -d
```

Las carpetas **versionadas** (`prometheus/`, `grafana/provisioning/`) no necesitan `chown`: se
montan en solo lectura y basta con que sean legibles para todos, que es como las deja `git clone`.

---

## Prometheus

### Cambiar la configuracion

Se edita `prometheus/prometheus.yml` y se reinicia. Antes de reiniciar, se valida: un error de
sintaxis deja a Prometheus sin arrancar.

```sh
docker run --rm -v "$PWD/prometheus:/cfg:ro" --entrypoint /bin/promtool \
  prom/prometheus:v3.15.0 check config /cfg/prometheus.yml
docker compose -f compose-dev.yaml restart prometheus
```

El archivo **se versiona y el repo es publico**: no pongas nombres de productos. Casi nunca hace
falta, porque las APIs empujan por OTLP y no se raspan.

### Cuanto guarda

`PROMETHEUS_RETENTION` en el `.env` (por omision `15d`). Pasado ese plazo borra lo mas viejo solo.
Para ver cuanto ocupa: `du -sh data/prometheus`.

### Respaldar y empezar de cero

- **Respaldo:** `docker compose -f compose-dev.yaml stop prometheus`, copia `data/prometheus`,
  y vuelve a levantarlo. Copiar la carpeta con Prometheus corriendo puede dejar una copia
  inconsistente.
- **De cero:** `stop prometheus`, `rm -rf data/prometheus/*`; `permisos-init` le devuelve el dueno en el siguiente `up`.

Son metricas de un entorno de desarrollo o staging: en la mayoria de los casos perderlas no
cuesta nada, y empezar de cero es mas barato que respaldar.

---

## Grafana

### Lo que se provisiona

`grafana/provisioning/` sigue la estructura que Grafana espera:

```
grafana/provisioning/
  datasources/
    prometheus.yml      la fuente de datos, apuntando a http://prometheus:9090
  dashboards/           (vacia hoy) proveedores de tableros, ver abajo
```

La fuente de datos llega con `editable: false`: se cambia en el archivo, no en la interfaz.

### Agregar un tablero que viaje con el repo

Un tablero hecho a mano en la interfaz vive solo en `grafana.db`. Para que lo traiga cualquier
clon:

1. Arma el tablero en la interfaz, y exportalo: *Share* -> *Export* -> *Save to file* (JSON).
2. Guarda el JSON en `grafana/provisioning/dashboards/json/<nombre>.json`.
3. Si todavia no existe, crea `grafana/provisioning/dashboards/tableros.yml`:

   ```yaml
   apiVersion: 1
   providers:
     - name: dev-stack
       folder: dev-stack
       type: file
       disableDeletion: true
       allowUiUpdates: false
       options:
         path: /etc/grafana/provisioning/dashboards/json
   ```

4. `docker compose -f compose-dev.yaml restart grafana`.

Al exportar, revisa que el JSON apunte a la fuente por su `uid`, `devstack-prometheus`, y que
no lleve nombres de productos en los titulos: el repo es publico. Filtra por producto con una
variable del tablero sobre la etiqueta `service_name`.

### Respaldar y empezar de cero

- **Respaldo:** `stop grafana`, copia `data/grafana/grafana.db`, levantalo. Es un SQLite: copiarlo
  con Grafana escribiendo puede dejarlo corrupto.
- **De cero:** `stop grafana`, `rm -rf data/grafana/*`; `permisos-init` le devuelve el dueno en el siguiente `up`. Al volver a
  levantarlo recrea el usuario admin con `GRAFANA_ADMIN_PASSWORD` y la fuente de datos por
  provisioning; se pierde lo que se hizo a mano en la interfaz.

### La contrasena de admin

`GRAFANA_ADMIN_USER` y `GRAFANA_ADMIN_PASSWORD` **solo aplican con `data/grafana` vacia**. Cambiarlos
en el `.env` despues no hace nada. Para cambiarla con Grafana ya creado:

```sh
docker exec devstack-grafana grafana cli admin reset-admin-password '<nueva>'
```

---

## Diagnostico

```sh
docker compose -f compose-dev.yaml ps prometheus grafana
docker compose -f compose-dev.yaml logs --tail 50 prometheus
docker compose -f compose-dev.yaml logs --tail 50 grafana
ls -ln data/                         # en Linux: el dueno debe ser 472 y 65534
```

| Sintoma | Causa |
|---|---|
| `up` termina con `container devstack-prometheus is unhealthy` | permisos de `data/prometheus`: mira `docker logs devstack-permisos-init` |
| Grafana reiniciandose, log con `is not writable` | permisos de `data/grafana`: igual |
| Grafana dice que la fuente de datos no responde | Prometheus no esta `healthy`; mira su log |
| Las metricas de un producto no aparecen | el producto no tiene `Observability__MetricsOtlpEndpoint`, o apunta a `localhost` desde un contenedor (ahi es `http://prometheus:9090/...`) |
| Muestras descartadas como `out of order` | el lote llego con mas de 30 min de atraso; ver `out_of_order_time_window` en `prometheus.yml` |
