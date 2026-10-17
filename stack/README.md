# stack - la infraestructura compartida

> Esta carpeta es el `stack/` del repo `dev-stack`. Todos los comandos de este documento se corren
> **desde aqui** (`cd dev-stack/stack`). Los runners de GitHub Actions estan al lado, en
> [`../actions-runner/`](../actions-runner/README.md).

Un solo Postgres, un solo MinIO, un solo Redis, un solo buzon de correo y un solo juego de
monitoreo (Seq, Prometheus, Grafana, Uptime Kuma, node-exporter y Dashy) para **todos** los
productos de la maquina.

Sin esto, cada repo levanta los suyos: varios Postgres, varios MinIO y varios Redis haciendo
exactamente lo mismo, cada uno con el puerto corrido para no chocar con el vecino, y aun asi
chocando.

## Aqui solo vive la infraestructura

`compose-dev.yaml` levanta Postgres, MinIO, Redis, Mailpit y el monitoreo (Seq, Prometheus,
Grafana, Uptime Kuma, node-exporter y Dashy). Nada mas.

**Las APIs y los frontends los levanta cada producto desde su propio repositorio**, con
`dotnet run` / `npm run dev` o con un `compose-dev.yaml` que se engancha a la red de este.
Cada repo es dueno de como se levanta lo suyo:

| Producto | Donde esta su compose |
|---|---|
| `{{PRODUCTO}}` (API y front en repos separados) | `{{WORKSPACE}}/{{PRODUCTO}}/{{PRODUCTO}}-webapi/compose-dev.yaml` |
| `{{PRODUCTO}}` (un solo repo) | `{{WORKSPACE}}/{{PRODUCTO}}/compose-dev.yaml` |
| `{{PRODUCTO}}` (sin compose) | *(ninguno)* — corre con `dotnet run` y `npm run dev` contra este stack |

Lo unico de este repo que sabe que productos existen es **`productos.conf`**, que no se
versiona. De ahi salen las bases, los roles y los buckets.

---

## Primera vez en una maquina

```sh
git clone git@github.com:{{ORG}}/dev-stack.git
cd dev-stack/stack
cp .env.example .env                       # OBLIGATORIO; cambia las contrasenas de Seq y Grafana
cp productos.conf.example productos.conf   # una linea por producto
nano minio.license                         # pega tu licencia de MinIO AIStor
docker compose -f compose-dev.yaml up -d
```

**El `.env` es obligatorio.** El compose no trae ningun puerto, usuario ni contrasena por
omision: todo sale de ahi, y si falta el archivo o una variable, `docker compose` se niega a
arrancar y dice cual (`required variable GRAFANA_PORT is missing a value`). Lo unico fijo en el
compose son las versiones de las imagenes.

`productos.conf` se lee **una sola vez**, en el primer arranque de Postgres (volumen vacio).
Si lo arrancas sin el, el init de Postgres falla y lo dice. Los buckets, en cambio, se crean
en cada `up`.

## Uso diario

```sh
docker compose -f compose-dev.yaml up -d
docker compose -f compose-dev.yaml ps
```

Todos los servicios deben decir `healthy`. `devstack-minio-init` aparece como `exited (0)` —
es correcto: crea los buckets y se apaga.

Despues, cada API con `dotnet run` desde su repo y cada front con `npm run dev`.

## Monitoreo

Cada pieza responde una pregunta distinta:

| Pieza | Responde | Se abre en (puertos del `.env.example`) |
|---|---|---|
| **Seq** | que paso: los logs de cada request | http://localhost:5380 |
| **Prometheus** | cuanto y que tan rapido: metricas | http://localhost:9090 |
| **Grafana** | verlo junto: tableros sobre Prometheus | http://localhost:3000 |
| **Uptime Kuma** | esta arriba o no: sondea el `/health` de cada API | http://localhost:3001 |
| **node-exporter** | como esta la maquina: CPU, memoria, carga, discos | no se abre: lo lee Prometheus y se mira en Grafana |
| **Dashy** | donde esta todo: una pagina con un link a cada cosa | http://localhost:4000 |

**node-exporter no publica puerto, a proposito.** Prometheus lo lee por su nombre en la red
`devstack` (`node-exporter:9100`). Su `/metrics` cuenta sin credenciales el detalle de discos,
montajes y kernel de la maquina, asi que no se publica ni por un puerto ni por un tunel: las
metricas se miran en Grafana. El tablero listo es **Node Exporter Full**: en Grafana,
*Dashboards -> New -> Import*, ID `1860`, fuente `Prometheus`.

Si la maquina ya tenia un node_exporter corriendo por su cuenta, sobra: bajalo y borralo
(`docker stop <nombre> && docker rm <nombre>`) para no tener dos. El del stack no choca con el
viejo mientras conviven, porque no usa el 9100 del host.

El detalle operativo de las carpetas de Grafana y Prometheus -que se versiona, respaldos, y los
permisos que hacen falta en un servidor Linux- esta en **[MONITOREO.md](MONITOREO.md)**.

### Dashy: la pagina de inicio

Su configuracion **se genera en cada arranque** desde `dashy/conf.template.yml` (versionado, solo
infraestructura) mas `dashy/productos.yml` (local, no versionado: los links a las APIs y fronts).
Los dos usan `DEVSTACK_HOST` (escrito entre arrobas), que sale del `.env`, asi que el mismo archivo sirve en tu maquina
y en el servidor. La edicion desde la interfaz esta apagada: lo que se cambiara ahi se perderia al
reiniciar. Para cambiar un link se edita el archivo y `restart dashy`.

```sh
cp dashy/productos.example.yml dashy/productos.yml   # una seccion por producto
```

### En un servidor (staging)

Estos valores del `.env` cambian respecto a tu maquina:

| Variable | En tu maquina | En el servidor |
|---|---|---|
| `DEVSTACK_BIND` | `127.0.0.1` | `127.0.0.1` si se publica por un tunel (ver abajo); si no, la IP de la red privada o VPN; `0.0.0.0` solo con firewall |
| `DEVSTACK_HOST` | `localhost` | el nombre o IP con que el navegador llega al servidor |
| `GRAFANA_ROOT_URL` | `http://localhost:3000` | la URL publica de Grafana, p. ej. `https://grafana.tudominio.com/`. Sin ella, un dashboard publico compartido llega apuntando a `localhost` |
| contrasenas | de desarrollo | **propias**: ya no es solo tu maquina |

**Varios servicios no piden credenciales**: la ingesta de Seq, el receptor OTLP de Prometheus,
Redis y Mailpit. Con `DEVSTACK_BIND=0.0.0.0` en un servidor con IP publica, cualquiera puede leer
y escribir en ellos. Los permisos de `data/` en Linux ya no son un paso manual: los resuelve
`permisos-init` en cada `up` (ver [MONITOREO.md](MONITOREO.md)).

### Detras de un tunel de Cloudflare

El tunel (`cloudflared`) entra al servidor desde adentro, asi que **nada tiene que escuchar en
una IP publica**: se deja `DEVSTACK_BIND=127.0.0.1` y cada ruta del tunel apunta al puerto
local. Si `cloudflared` corre en un contenedor en vez de en el host, ahi `localhost` es el
propio contenedor: tiene que estar en la red `devstack` y apuntar por nombre y puerto interno.

**Se publican solo las interfaces web**, y cada hostname detras de **Cloudflare Access** con una
politica que deje pasar solo a quien corresponde:

| Ruta del tunel | `cloudflared` en el host | `cloudflared` en la red `devstack` |
|---|---|---|
| Dashy | `http://localhost:4000` | `http://dashy:8080` |
| Grafana | `http://localhost:3000` | `http://grafana:3000` |
| Seq (interfaz) | `http://localhost:5380` | `http://seq:80` |
| Uptime Kuma | `http://localhost:3001` | `http://uptime-kuma:3001` |
| Prometheus | `http://localhost:9090` | `http://prometheus:9090` |
| MinIO (consola) | `http://localhost:9001` | `http://minio:9001` |
| Mailpit (bandeja) | `http://localhost:8025` | `http://mailpit:8025` |

Ojo con Mailpit: su bandeja web es el **8025**. El 1110 que muestra `docker ps` es su POP3
interno, y una ruta ahi no carga.

**No se publican**, ni con Access: Postgres, Redis, el SMTP de Mailpit (1025), la ingesta de
Seq (5341), el receptor OTLP de Prometheus, el node-exporter ni el proxy del socket de Docker.
Los tres primeros ni siquiera son HTTP, y los productos del mismo servidor ya los alcanzan por
la red `devstack`. **Mailpit es el mas delicado** de los publicados: su bandeja trae los correos
de recuperacion de contrasena y los codigos de acceso de todos los productos.

**Dashboard publico de Grafana** (compartido con externos): con Access delante, a un externo
tambien le pediria login. En la aplicacion de Access de Grafana, una politica **Bypass** para
`/public-dashboards/*`, `/api/public/*` y `/public/*` deja pasar solo eso. Y
`GRAFANA_ROOT_URL` tiene que ser la URL publica, o el link sale con `localhost`. Que tablero
compartir: [MONITOREO.md](MONITOREO.md), seccion del tablero "Servidor".

**Limitacion conocida -- los links de Dashy.** Dashy arma cada link como
`http://DEVSTACK_HOST:puerto`, y detras de un tunel cada servicio tiene su propio hostname con
HTTPS y sin puerto: esos links no sirven. Mientras no haya una URL publica por servicio en el
`.env`, Dashy se usa como pagina de inicio en la maquina local, no por el tunel.

Si el tunel no carga un hostname que si responde en el servidor (`curl localhost:<puerto>`), y
el navegador corta la conexion en el TLS, el problema esta del lado de Cloudflare: revisa en
*DNS* que el registro sea un CNAME al tunel con la nube naranja, igual que uno que funcione. Si
ya habia un registro con ese nombre al crear la ruta, Cloudflare no lo reemplaza.

### Conectar un producto

| Para | Variable en el `.env` del producto |
|---|---|
| Logs a Seq | `Seq__ServerUrl=http://localhost:5341` (desde un contenedor: `http://seq:5341`) |
| Metricas a Prometheus | `Observability__MetricsOtlpEndpoint=http://localhost:9090/api/v1/otlp/v1/metrics` (desde un contenedor: `http://prometheus:9090/...`) |

**Las APIs no exponen `/metrics`: empujan.** Desde Common v2.1 las metricas salen por OTLP al
receptor de Prometheus, que el compose enciende con `--web.enable-otlp-receiver`. Por eso
`prometheus/prometheus.yml` casi no tiene `scrape_configs`. Cada metrica llega con la etiqueta
`service_name` del producto, para filtrar las graficas por producto.

**Seq tiene dos puertos y no son intercambiables.** `SEQ_INGESTION_PORT` (5341) solo recibe
logs; `SEQ_UI_PORT` (5380) es la interfaz, con login. Los productos ya apuntaban al 5341, asi
que para ellos no cambia nada.

**Uptime Kuma** no se configura por archivo: los monitores se dan de alta en su interfaz. Una
API que corre con `dotnet run` se sondea como `http://host.docker.internal:<puerto>/health/live`;
una en contenedor de la red `devstack`, por su nombre de servicio.

**Para vigilar contenedores** (monitor tipo *Docker Container*), Kuma **no** tiene el socket de
Docker: quien lo tiene manda sobre la maquina entera, y Kuma esta publicado. Lo tiene el servicio
`docker-socket-proxy`, que solo deja pasar lecturas de contenedores; cualquier `POST` -detener,
arrancar, `exec`- responde `403`. Se configura una vez en Kuma:

1. *Settings -> Docker Hosts -> Setup Docker Host*: tipo **TCP / HTTP**, URL
   **`http://docker-socket-proxy:2375`**.
2. Al crear el monitor *Docker Container*, ese host, y como contenedor el **nombre** que muestra
   `docker ps` (p. ej. `devstack-postgres`).

Poner `/var/run/docker.sock` como host en Kuma no funciona: ese archivo no existe dentro de su
contenedor, a proposito.

**El diseno de una pagina de status** se cambia en *Status Pages -> la pagina -> Edit Status
Page -> Custom CSS*. Ese CSS se guarda en la base de Kuma (`data/uptime-kuma/kuma.db`), no en el
repo: si importa, guarda una copia aparte. Usa las clases estables (`.title`, `.description`,
`.overall-status`, `.shadow-box`, `.group-title`, `.item`, `.item-name`, `.incident`,
`.dark`) y no los atributos `[data-v-...]`, que cambian con cada version de Kuma.

### Stripe en modo prueba (perfil `stripe`)

Los webhooks de Stripe necesitan llegar a la API, y en desarrollo la API no tiene una URL
publica. El servicio `stripe-cli` lo resuelve: corre un `stripe listen` por producto que
recibe los eventos de la cuenta de prueba de ese producto y los reenvia a su API.

```sh
cp stripe.conf.example stripe.conf      # una linea por producto que cobre con Stripe
docker compose -f compose-dev.yaml --profile stripe up -d
docker logs devstack-stripe-cli | grep "secreto de firma"
```

- **Solo arranca con el perfil `stripe`.** Una maquina sin productos que cobren no necesita
  `stripe.conf` ni este contenedor.
- **Una llave por producto, y de prueba.** Cada linea lleva la `sk_test_` de la cuenta de ese
  producto; lo mas limpio es un *sandbox* de Stripe por producto. El script se niega a arrancar
  con dos productos que comparten llave (cada API procesaria los cobros de la otra), con una llave
  live, o con la llave de ejemplo sin cambiar.
- **El secreto de firma** (`whsec_...`) de cada producto sale en el log al arrancar y va en el
  `.env` del producto como su secreto de webhook. Es fijo por cuenta: no cambia al reiniciar.
- **El destino se escribe como lo ve el contenedor:** `http://host.docker.internal:<puerto>/...`
  para una API con `dotnet run` o publicada en un puerto de la maquina (asi es staging), o
  `http://<contenedor>:<puerto>/...` para una API en contenedor en la red `devstack`.
- **Si un listener se cae, se reinicia el contenedor entero**: un listener muerto no pasa
  desapercibido. `docker logs -f devstack-stripe-cli` muestra cada evento con el nombre del
  producto delante.
- **No uses a la vez este listener y un webhook del dashboard** apuntando a la misma API: cada
  evento llegaria dos veces. La API lo aguanta (es idempotente), pero el log se vuelve confuso.

### Primer arranque: las contrasenas

- **Seq** crea el usuario `SEQ_ADMIN_USER` con `SEQ_ADMIN_PASSWORD`, y **en el primer login
  exige cambiarla**. La del `.env` solo sirve esa vez; despues manda la que pongas en la
  interfaz.
- **Grafana** crea `GRAFANA_ADMIN_USER` con `GRAFANA_ADMIN_PASSWORD`.
- **Uptime Kuma** no acepta usuario por variable: lo pide su asistente la primera vez que abres
  la interfaz.

En los tres, las variables **solo aplican con la carpeta de datos vacia**. Cambiarlas en `.env`
despues no cambia nada: la contrasena se cambia desde la interfaz.

### Donde viven los datos

En **`./data/<servicio>`**, junto al compose, y no se versiona. Se respalda copiando la carpeta,
y para empezar de cero un servicio se baja y se borra su carpeta.

Postgres, MinIO y Redis **siguen en volumenes con nombre**, a proposito: Postgres exige que su
directorio sea del usuario `postgres` con permisos `0700`, cosa que una carpeta de Windows montada
no cumple, y ademas tienen los datos de todos los productos. Moverlos a `./data` es una migracion
con respaldo, no un cambio de una linea.

### Levantar un producto entero en contenedores

Primero la infraestructura, **una vez para toda la maquina**, y luego el producto desde su repo:

```sh
cd {{WORKSPACE}}/{{PRODUCTO}}/{{PRODUCTO}}-webapi
docker compose -f compose-dev.yaml up -d --build     # API + front
```

El compose del producto declara la red `devstack` como **externa**, asi que si la
infraestructura no esta arriba falla diciendo que la red no existe. Es el error que se quiere.

Si vas a levantar varios productos, hazlo **de uno en uno**: dos builds .NET en paralelo
saturan la maquina y provocan timeouts en otras suites que parecen defectos de codigo.

### Los frontends en contenedor pierden el hot reload

Vite **hornea las variables `VITE_*` en el bundle en tiempo de build**: cambiar el codigo
-o el puerto de la API- obliga a reconstruir la imagen. Para desarrollar el front,
`npm run dev`. `VITE_API_BASE_URL` apunta al **puerto publicado en la maquina** y no al
nombre del servicio, porque quien hace la peticion es el navegador, fuera de la red de Docker.

Si la API no publica cabeceras CORS, el front en contenedor necesita que su nginx haga de
proxy y un bundle sin `VITE_API_BASE_URL`, para que todo salga por el mismo origen.

### Bajar todo

```sh
docker compose -f compose-dev.yaml down      # conserva los datos
./bajar-todo.sh                              # todos los contenedores de la maquina
docker compose -f compose-dev.yaml down -v   # BORRA bases y buckets de todos los productos
```

`bajar-todo.sh` lista lo que va a parar y pide confirmacion. **Nunca** borra volumenes.

`down -v` borra los volumenes con nombre (Postgres, MinIO, Redis) pero **no** `./data`: los logs,
metricas, tableros y monitores sobreviven. Para borrarlos, se borra la carpeta.

### Runners de GitHub Actions

En [`../actions-runner/`](../actions-runner/README.md), al lado de esta carpeta y aparte de este compose: N runners self-hosted en
contenedores sobre la imagen oficial, con su propio `compose.yaml` y su propio `.env` (lleva el token de
registro). `compose-dev.yaml` no los toca, pero **`bajar-todo.sh` si los para**: detiene todo contenedor
que siga corriendo. Despues de usarlo, `docker compose up -d` dentro de `../actions-runner/` para
recuperarlos.

---

## Como esta armado

### Una instancia de Postgres, una base por producto

```
devstack-postgres :5432
 ├── {{DB_PRODUCTO_A}}   owner {{PRODUCTO_A}}_owner
 ├── {{DB_PRODUCTO_B}}   owner {{PRODUCTO_B}}_owner   + rol de app {{PRODUCTO_B}}_app
 └── ...                 una linea de productos.conf = una base
```

Una base por producto y no un esquema compartido, porque varios historiales de migraciones
EF sobre las mismas tablas se destruyen entre si al primer `dotnet ef database update`.

**Cada producto tiene su propio rol owner y ninguno usa `postgres`.** Con un superusuario
compartido, una cadena de conexion con el `Database=` equivocado no falla: conecta, y la API
le aplica *sus* migraciones a la base de otro producto. Con un owner por producto la
conexion equivocada falla en el acto.

**Los productos con Row Level Security tienen ademas un rol de aplicacion**, porque RLS
**solo tiene efecto si quien se conecta no es superusuario ni tiene BYPASSRLS**. Un
superusuario ignora las policies sin ningun sintoma: las consultas funcionan y devuelven
datos de todos los tenants. La app entra con `_app`; las migraciones, con el owner.

El detalle de cada columna de `productos.conf` esta en `productos.conf.example`, y el porque
de cada privilegio en la cabecera de `init/postgres/00-bases-y-roles.sh`.

### El init de Postgres corre una sola vez

`init/postgres/00-bases-y-roles.sh` se ejecuta en la **primera** inicializacion, con el
volumen vacio, y nunca mas. Para un producto nuevo en un stack con datos, crea su base y su
rol a mano, o recrea el volumen (`down -v` y `up -d`), que borra los datos de todos.

Y **no crea las policies de RLS**: si un producto las tiene en un script suelto y no en sus
migraciones, la base queda sin esa barrera y nada lo delata. Despues de migrar, comprueba
que con la conexion de la app y sin fijar el tenant, un `SELECT count(*)` devuelva 0.

---

## Cosas que muerden

### Dos APIs en el mismo puerto no dan error

Cuando dos APIs se pelean un puerto, la que perdio no avisa: parece que la tuya esta arriba
y le estas pegando a la del vecino. Si sus `/health` tienen la misma forma, solo se
distinguen por los nombres de los checks. Ver `PUERTOS.md`.

### El `5000` y el `7000` los sirve AirPlay (macOS)

AirPlay Receiver responde `403` a todo con `Server: AirTunes`. Si una API se pone ahi, el
proxy de Vite reenvia a AirPlay y la aplicacion falla con un error que apunta al backend.

### Las URLs prefirmadas de MinIO, con las APIs en contenedor

La firma S3 v4 incluye el host: la URL que la API firma tiene que ser la que abre el
navegador. Desde un contenedor MinIO es `minio:9000`; desde el navegador, `localhost:9000`.
En modo `dotnet run` no hay problema. Con las APIs en contenedor, o separas el endpoint
interno del publico con el que se firma, o haces que `minio` signifique lo mismo fuera:

```sh
echo "127.0.0.1 minio" | sudo tee -a /etc/hosts
```

### MinIO necesita licencia

El stack usa la imagen oficial de **MinIO AIStor** (`quay.io/minio/aistor/minio`), que exige
una licencia; la del plan gratuito basta. Se pide en la pagina de precios de MinIO AIStor
(plan *Free*, *Get Started*) y se guarda en `minio.license`, junto al compose.

`minio.license` **no se versiona**: el repo es publico y la licencia esta ligada a tu cuenta.
En cada maquina hay que crearlo a mano.

Sin licencia valida el servidor **arranca igual** pero en *offline mode*: rechaza toda
operacion S3 y nunca se declara listo. El sintoma es `devstack-minio` en `unhealthy` y
`minio-init` sin correr. Confirmalo con:

```sh
docker logs devstack-minio 2>&1 | grep -i license
```

`minio/minio` y `minio/mc` ya no existen en ningun registro (MinIO los retiro en 2025): si
un `up` falla y **todos** los servicios salen como `Interrupted`, busca la linea
`pull access denied`. Si prefieres no depender de una licencia, `pgsty/minio` es la build
comunitaria del mismo codigo; el cambio esta descrito en `compose-dev.yaml`.

### Los archivos locales se quedan en la raiz al migrar del layout viejo

Antes del **2026-09-30** el compose vivia en la raiz del repo, y con el los cuatro archivos que
**no** se versionan: `.env`, `productos.conf`, `minio.license` y los datos. La reorganizacion movio
lo versionado a `stack/`, pero **los locales no se mueven solos**: siguen donde estaban hasta que
alguien corra el paso de migracion.

El sintoma no apunta a eso. En una maquina donde no se corrio:

```
ERROR: falta productos.conf. Copia productos.conf.example a productos.conf
```

...y `productos.conf` **si existe** -- en la raiz --, asi que el mensaje parece mentir. Con
`minio.license` es peor, porque el compose monta `./:/devstack:ro`, o sea **su propio
directorio**: si el archivo esta en la raiz, MinIO arranca en *offline mode* sin decir que no lo
encontro.

Comprueba donde estan antes de dar por hecho que faltan:

```sh
ls minio.license productos.conf stack/minio.license stack/productos.conf
```

Y si estan en la raiz, copialos -- no los muevas: otra herramienta tuya puede seguir leyendolos de
ahi --:

```sh
cp -p minio.license productos.conf stack/
cd stack && docker compose -f compose-dev.yaml up -d minio minio-init
```

**Solo esos dos servicios**, no `up -d` a secas: un arranque completo recrea Postgres y se lleva por
delante las APIs que esten corriendo contra el.

### Las bases logicas de Redis no aislan

`FLUSHALL` las borra todas y no hay permisos por base. Bastan en desarrollo.

---

## Diagnostico

```sh
docker compose -f compose-dev.yaml ps
docker compose -f compose-dev.yaml logs postgres       # por que no se crearon las bases
docker compose -f compose-dev.yaml logs minio-init     # que buckets hay
docker exec devstack-postgres psql -U postgres -c "\l" # las bases
docker exec devstack-postgres psql -U postgres -c "\du" # los roles: ningun _app superusuario
lsof -nP -iTCP:5432 -sTCP:LISTEN                       # quien tiene el puerto
```

Si `up` falla con *port is already allocated*, hay un contenedor viejo en el puerto:
`./bajar-todo.sh`.

### Bajo carga, `docker ps` miente

Con la maquina saturada -un build .NET basta- `docker ps` puede **expirar y devolver una
lista vacia**, y `nc -z localhost 5432` dar cerrado, con el stack sano. Contrastalo:

```sh
docker info | grep -E "Containers|Running"   # responde cuando `ps` no
uptime                                        # si el load pasa de 10, es esto
```
