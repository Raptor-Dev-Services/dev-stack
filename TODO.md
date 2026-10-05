# Pendientes del dev-stack

## Limpieza programada de Docker (pedida el 2026-10-05)

**Problema:** los pipelines (webapi, webclient, appmobile) van dejando imágenes, capas y caché de build en el
Docker del server, y el disco se llena.

**Lo que NO se hace, y por qué:** `docker system prune` (y menos `-a --volumes`) al final de cada pipeline.

- Los runners comparten el Docker del server con el Postgres de staging, MinIO, Redis, Harbor, el monitoreo
  y las APIs de staging. `--volumes` borra todo volumen que no esté en uso en ese instante: si el Postgres o
  MinIO están detenidos un momento (un reinicio, `bajar-todo.sh`), se pierden sus datos sin vuelta atrás.
- Son 4 runners en paralelo: el prune de un job borra la imagen que otro job está usando o acaba de bajar,
  y ese build truena sin razón aparente.
- `-a` borra la imagen de Android (~3 GB, se reconstruye), las del SDK de .NET y Node, y la caché de build:
  todos los builds vuelven a ser lentos.
- Hasta el `prune` simple borra contenedores detenidos, y un contenedor del stack apagado a propósito es uno.

**Lo que se va a hacer:**

- [ ] Revisar que cada pipeline limpie solo lo suyo (hoy todos los pasos usan `docker run --rm` y los Postgres
      de Testcontainers se borran solos). Confirmarlo y corregir el paso que deje algo.
- [ ] Limpieza **una vez al día en la madrugada**, cuando no corre nada, con filtros seguros:
  - [ ] contenedores detenidos con más de 24 h: `docker container prune --filter "until=24h"`;
  - [ ] imágenes sin usar con más de 7 días: `docker image prune -a --filter "until=168h"`, respetando las
        que tengan una etiqueta de "conservar" (por ejemplo la imagen de build de Android);
  - [ ] caché de build con más de 7 días, dejando un mínimo para que los builds sigan rápidos:
        `docker builder prune --filter "until=168h" --keep-storage 20gb`;
  - [ ] **nunca volúmenes**.
- [ ] Que imprima el espacio antes y después (`docker system df`) para ver cuánto libera.
- [ ] Dónde: mi apuesta es un **workflow programado (`schedule`) en este repo** que corra en los runners
      propios, para que quede versionado y se vea en GitHub cuándo corrió y cuánto liberó. La alternativa es
      un script con un timer de systemd en el server.
- [ ] Documentarlo en `actions-runner/README.md`, en la sección "Recursos: CPU y disco".
