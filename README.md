# dev-stack

La infraestructura compartida de los proyectos de la organizacion, en dos carpetas que se levantan
cada una por su lado:

| Carpeta | Que es | Se levanta con |
|---|---|---|
| [`stack/`](stack/README.md) | La infraestructura: Postgres, MinIO, Redis, Mailpit y el monitoreo (Seq, Prometheus, Grafana, Uptime Kuma, node-exporter, Dashy), con su configuracion, sus datos y su documentacion | `cd stack && docker compose -f compose-dev.yaml up -d` |
| [`actions-runner/`](actions-runner/README.md) | Los runners self-hosted de GitHub Actions, en contenedores | `cd actions-runner && docker compose up -d` |

Cada carpeta tiene su propio `.env` (obligatorio, se copia de su `.env.example`) y su propio README.
Del stack hay ademas [`stack/MONITOREO.md`](stack/MONITOREO.md) (Grafana, Prometheus,
node-exporter) y [`stack/PUERTOS.md`](stack/PUERTOS.md) (el mapa de puertos).

## Si tu clon es de antes de `stack/`

Hasta el 2026-09-30 el stack vivia en la raiz del repo. `git pull` mueve lo versionado, pero **no
mueve lo que git no versiona**, y eso es justo lo que tiene los datos y las credenciales. Sin este
paso, el stack arranca **sin `.env`** (compose se niega) o, peor, con `data/` vacia: Grafana, Seq y
Uptime Kuma aparecerian como recien instalados.

```sh
cd <ruta-del-clon>                                  # p. ej. ~/Docker/dev-stack
docker compose -f compose-dev.yaml stop             # ANTES del pull: con el compose viejo, desde la raiz
git pull
for f in .env productos.conf minio.license data dashy/productos.yml; do
  [ -e "$f" ] && mv "$f" "stack/$f" && echo "movido: $f"
done
rmdir dashy 2>/dev/null
cd stack
docker compose -f compose-dev.yaml up -d
```

- Postgres, MinIO y Redis **no** se mueven: viven en volumenes de Docker con nombre
  (`devstack_devstack-pg`, ...), y el nombre del proyecto (`devstack`) no cambia.
- `stop` y no `down`: `down` intenta borrar la red `devstack`, y falla si hay APIs de productos
  conectadas a ella.
- Si ya hiciste el `pull` antes del `stop`, el `stop` igual funciona desde `stack/` cuando ya
  moviste el `.env`; los contenedores son los mismos.
- En Linux, `data/` conserva su dueno al moverla dentro del mismo disco; `permisos-init` lo
  revisa igual en cada `up`.
