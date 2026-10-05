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

- [x] Revisar que cada pipeline limpie solo lo suyo. **Confirmado el 2026-10-05** en los tres repos de SocioFit:
      todo `docker run` lleva `--rm`; el unico `docker create` (leer el SQL de la imagen distroless de la API)
      hace `docker rm -f` despues. Lo que si se acumula son las imagenes que construyen (`docker build`).
- [x] Limpieza **una vez al dia en la madrugada** (2026-10-05): `mantenimiento/limpiar-docker.sh`, corrido por
      `.github/workflows/limpieza-docker.yml` (04:00 de Ciudad de Mexico). **Arranca en seco**; se enciende con
      la variable del repo `LIMPIEZA_DOCKER_REAL=true`. Se cambio el plan original en un punto: no se usa
      `docker image prune -a --filter until=168h`, porque `until` mira cuando se CREO la imagen y borraria cada
      noche las imagenes base (SDK de .NET, Node), que casi siempre se crearon hace mas de 7 dias. En su lugar,
      de las imagenes PROPIAS (Harbor y la de build de Android) se conservan las 3 mas recientes por
      repositorio; las base no se tocan. Contenedores detenidos de mas de 24 h fuera de compose, imagenes
      colgadas de mas de 24 h y cache de build de mas de 7 dias con 20 GB minimos. Nunca volumenes.
- [ ] **Bloqueado: el repo es publico.** Por omision GitHub no deja que un repo publico use los runners del
      grupo de la organizacion, y si se permite, un fork podria intentar correr codigo en el server (el
      workflow solo escucha `schedule` y `workflow_dispatch` para cerrar eso). Decidir: hacer `dev-stack`
      privado, o permitir repos publicos en el grupo de runners, o mover la limpieza a un timer de systemd
      en el server con el mismo script.
- [ ] Primera corrida en seco revisada y encendido real.
- [x] Documentarlo en `actions-runner/README.md`, en la seccion "Recursos: CPU y disco".
