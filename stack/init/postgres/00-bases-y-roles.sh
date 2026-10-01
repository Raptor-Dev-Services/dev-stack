#!/bin/sh
# =============================================================================
# 00-bases-y-roles.sh - Provisiona el Postgres COMPARTIDO del stack de desarrollo
# =============================================================================
# Una instancia con UNA BASE POR PRODUCTO, que es como se ve produccion (un RDS/Aurora
# con varias bases) y lo unico que no destruye las migraciones EF de cada producto: varios
# historiales de migraciones sobre las mismas tablas se pisan entre si al primer
# `dotnet ef database update`.
#
# Los productos salen de /devstack/productos.conf (ver productos.conf.example). Este
# script no conoce ninguno.
#
# SOLO CORRE UNA VEZ, con el volumen de datos vacio: la imagen de Postgres ejecuta
# /docker-entrypoint-initdb.d/* en la PRIMERA inicializacion y nunca mas. Para que un
# cambio surta efecto hay que recrear el volumen (`down -v` y `up -d`), que borra los datos.
#
# -----------------------------------------------------------------------------
# POR QUE CADA PRODUCTO TIENE SU PROPIO ROL OWNER Y NO USA `postgres`
# -----------------------------------------------------------------------------
# Con un superusuario compartido, una cadena de conexion con el `Database=` equivocado no
# falla: conecta, y la API le aplica SUS migraciones a la base de OTRO producto. Con un
# owner por producto la conexion equivocada falla en el acto, con un mensaje que dice
# exactamente que paso. NOSUPERUSER en todos: es lo que hace real el aislamiento.
#
# -----------------------------------------------------------------------------
# POR QUE UN ROL DE APLICACION EN LOS PRODUCTOS CON RLS
# -----------------------------------------------------------------------------
# RLS solo tiene efecto si quien se conecta NO es superusuario y NO tiene BYPASSRLS: un
# superusuario ignora las policies SIN NINGUN SINTOMA, las consultas funcionan y devuelven
# datos de todos los tenants. La app corre con `<prefijo>_app` (sin BYPASSRLS) y las
# migraciones con el owner.
#
# El owner SI lleva BYPASSRLS cuando rls=si: con FORCE ROW LEVEL SECURITY las policies
# aplican tambien al dueno de la tabla, y sin BYPASSRLS no puede sembrar datos de dos
# tenants, que es la precondicion de cualquier prueba de aislamiento (se PREPARA con el
# owner y se MIDE con la app). No debilita la barrera: la app no entra con el owner.
#
# -----------------------------------------------------------------------------
# LO QUE ESTE SCRIPT **NO** HACE
# -----------------------------------------------------------------------------
# Las POLICIES de RLS. Si un producto las tiene en un script suelto y no en sus
# migraciones, una base creada solo con `dotnet ef database update` queda con una sola
# barrera -el filtro de la aplicacion- y nada lo delata. Despues de migrar, comprueba
# que existan:
#     SELECT count(*) FROM pg_policies WHERE schemaname = 'public';
# y que con la conexion de la APP, sin fijar el tenant, un `SELECT count(*)` sobre una
# tabla con datos devuelva 0.
#
# Contrasenas: `<rol>_dev`, de DESARROLLO LOCAL y triviales a proposito. Este Postgres
# solo escucha en la maquina de desarrollo; no reutilices ninguna fuera de aqui.
# =============================================================================
set -eu

CONF=/devstack/productos.conf

if [ ! -f "$CONF" ]; then
    echo "ERROR: falta productos.conf. Copia productos.conf.example a productos.conf" >&2
    echo "       y pon una linea por producto antes del primer arranque." >&2
    exit 1
fi

sql() {
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$1"
}

# Por omision PUBLIC puede conectarse a cualquier base. Se revoca en `postgres` aqui y en
# cada base de producto abajo, para que un owner no pueda escribir en la de otro.
echo "REVOKE ALL ON DATABASE postgres FROM PUBLIC;" | sql postgres

grep -v '^[[:space:]]*#' "$CONF" | grep -v '^[[:space:]]*$' |
while read -r base prefijo rls app createrole buckets resto; do
    if [ -z "$buckets" ] || [ -n "$resto" ]; then
        echo "ERROR en productos.conf: la linea de '$base' no tiene 6 columnas" >&2
        exit 1
    fi
    case "$rls$createrole" in sisi|sino|nosi|nono) ;; *)
        echo "ERROR en productos.conf ($base): rls y createrole son si|no" >&2; exit 1 ;;
    esac
    case "$app" in no|conexion|dml) ;; *)
        echo "ERROR en productos.conf ($base): app es no|conexion|dml, no '$app'" >&2; exit 1 ;;
    esac

    owner="${prefijo}_owner"
    rol_app="${prefijo}_app"
    atributos="LOGIN NOSUPERUSER"
    [ "$rls" = si ] && atributos="$atributos BYPASSRLS"
    [ "$createrole" = si ] && atributos="$atributos CREATEROLE"

    echo "==> $base (owner $owner, app $app)"

    # El locale se fija para que los ordenamientos de texto no cambien entre maquinas:
    # sin esto la misma consulta ordena distinto en tu equipo y en CI.
    sql postgres <<SQL
CREATE ROLE $owner $atributos PASSWORD '${owner}_dev';
CREATE DATABASE $base OWNER $owner ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
REVOKE CONNECT ON DATABASE $base FROM PUBLIC;
SQL

    # El owner es dueno de la base, pero el esquema public sigue siendo de `postgres`: sin
    # esto las migraciones no pueden crear tablas.
    echo "ALTER SCHEMA public OWNER TO $owner;" | sql "$base"

    if [ "$app" != no ]; then
        # Si una migracion del producto tambien crea este rol, la suya debe envolverlo en
        # `IF NOT EXISTS`: la de aqui gana y trae la contrasena de desarrollo ya puesta.
        sql "$base" <<SQL
CREATE ROLE $rol_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE PASSWORD '${rol_app}_dev';
GRANT CONNECT ON DATABASE $base TO $rol_app;
SQL
    fi

    if [ "$app" = dml ]; then
        # Los DEFAULT PRIVILEGES se cuelgan del rol que CREA los objetos, por eso van
        # FOR ROLE owner: las tablas de migraciones futuras quedan accesibles sin mas GRANT.
        sql "$base" <<SQL
GRANT USAGE ON SCHEMA public TO $rol_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $rol_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $rol_app;
ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $rol_app;
ALTER DEFAULT PRIVILEGES FOR ROLE $owner IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO $rol_app;
SQL
    fi
done
