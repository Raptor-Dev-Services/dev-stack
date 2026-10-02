#!/bin/sh
# =============================================================================
# escuchar.sh - un `stripe listen` por producto, todos en el contenedor stripe-cli
# =============================================================================
# Lee /stripe/stripe.conf (montado de ./stripe.conf, NO versionado). Una linea por producto:
#
#   producto   llave-de-prueba   url-de-destino   [eventos separados por coma]
#
# Cada producto reenvia los eventos de SU cuenta de Stripe a SU API, con SU secreto de firma: por
# eso hay una llave por linea y no una global. Dos lineas con la misma llave recibirian los mismos
# eventos (los de esa cuenta) y cada API procesaria los cobros de la otra: se rechaza al arrancar.
#
# Solo llaves de PRUEBA (sk_test_ / rk_test_). Una llave live en un stack de desarrollo es un
# accidente esperando a pasar: se rechaza al arrancar, no se "intenta".
#
# Si cualquier listener se cae, el script termina con error y Docker reinicia el contenedor
# (restart: unless-stopped). Asi un listener muerto no pasa desapercibido mientras los demas siguen.
# =============================================================================
set -eu

CONF=/stripe/stripe.conf

if [ ! -f "$CONF" ]; then
  echo "[stripe] Falta stripe.conf junto al compose. Copia stripe.conf.example a stripe.conf." >&2
  exit 1
fi

pids=""
llaves=""
lineas=0

# `tr -d '\r'`: un stripe.conf guardado en Windows trae CRLF, y el \r pegado a la URL o a la llave
# hace fallar el listener con un error que no lo menciona.
while read -r producto llave destino eventos _resto; do
  case "$producto" in ''|\#*) continue ;; esac

  if [ -z "$llave" ] || [ -z "$destino" ]; then
    echo "[stripe] Linea incompleta para '$producto': faltan la llave o la URL de destino." >&2
    exit 1
  fi
  case "$llave" in
    *CAMBIAME*)
      echo "[stripe] '$producto' sigue con la llave de ejemplo: pon la sk_test_ real de su cuenta." >&2
      exit 1 ;;
    sk_test_*|rk_test_*) ;;
    sk_live_*|rk_live_*)
      echo "[stripe] '$producto' tiene una llave LIVE. Este stack solo acepta llaves de prueba." >&2
      exit 1 ;;
    *)
      echo "[stripe] La llave de '$producto' no parece una llave de Stripe (sk_test_... o rk_test_...)." >&2
      exit 1 ;;
  esac
  case " $llaves " in
    *" $llave "*)
      echo "[stripe] '$producto' repite una llave de otra linea: los dos recibirian los eventos del otro. Usa un sandbox de Stripe por producto." >&2
      exit 1 ;;
  esac
  llaves="$llaves $llave"

  # El secreto de firma de `stripe listen` es fijo por cuenta: se imprime para pegarlo en el .env
  # del producto (su WebhookSecret). No es la llave: verifica que el evento vino de este listener.
  secreto=$(stripe listen --api-key "$llave" --print-secret 2>/dev/null || true)
  echo "[stripe] $producto -> $destino | secreto de firma para su .env: ${secreto:-(no se pudo obtener: revisa la llave)}"

  if [ -n "${eventos:-}" ]; then
    stripe listen --api-key "$llave" --device-name "devstack-$producto" \
      --forward-to "$destino" --events "$eventos" 2>&1 | sed "s/^/[$producto] /" &
  else
    # Sin lista, todos los eventos clasicos de la cuenta: la CLI ya no tiene un "todos" implicito
    # (exige --events, --all-snapshot o --all-thin, y sin ninguno termina con error).
    stripe listen --api-key "$llave" --device-name "devstack-$producto" \
      --forward-to "$destino" --all-snapshot 2>&1 | sed "s/^/[$producto] /" &
  fi
  pids="$pids $!"
  lineas=$((lineas + 1))
done <<EOF
$(tr -d '\r' < "$CONF")
EOF

if [ "$lineas" -eq 0 ]; then
  echo "[stripe] stripe.conf no tiene ningun producto. Agrega una linea o apaga el perfil stripe." >&2
  exit 1
fi

# Espera a que CUALQUIERA termine: un listener caido tumba el contenedor y Docker lo levanta de nuevo.
while :; do
  for pid in $pids; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[stripe] Un listener termino; se reinicia el contenedor." >&2
      exit 1
    fi
  done
  sleep 5
done
