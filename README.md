# dev-stack — la infraestructura de desarrollo compartida

Un solo Postgres, un solo MinIO, un solo Redis, un solo buzon de correo y un solo servidor
de logs para **todos** los productos de la maquina.

Sin esto, cada repo levanta los suyos: varios Postgres, varios MinIO y varios Redis haciendo
exactamente lo mismo, cada uno con el puerto corrido para no chocar con el vecino, y aun asi
chocando.

## Aqui solo vive la infraestructura

`compose-dev.yaml` levanta Postgres, MinIO, Redis, Mailpit y Seq. Nada mas.

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
cd dev-stack
cp productos.conf.example productos.conf   # una linea por producto
nano minio.license                         # pega tu licencia de MinIO AIStor
cp .env.example .env                       # opcional: solo si te choca un puerto
docker compose -f compose-dev.yaml up -d
```

`productos.conf` se lee **una sola vez**, en el primer arranque de Postgres (volumen vacio).
Si lo arrancas sin el, el init de Postgres falla y lo dice. Los buckets, en cambio, se crean
en cada `up`.

## Uso diario

```sh
docker compose -f compose-dev.yaml up -d
docker compose -f compose-dev.yaml ps
```

Los servicios deben decir `healthy` (Seq no tiene sonda y dice solo `running`).
`devstack-minio-init` aparece como `exited (0)` — es correcto: crea los buckets y se apaga.

Despues, cada API con `dotnet run` desde su repo y cada front con `npm run dev`.

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
