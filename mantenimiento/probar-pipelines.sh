#!/bin/sh
# Pruebas para aislar que parte de un pipeline tira el server. Una a la vez; ver mantenimiento/CUELGUES.md,
# "Que tiene CI que no tienen las pruebas sinteticas".
#
# Uso (como raptor, NO hace falta sudo; Docker tiene que estar arriba salvo en `disco` y `rafagas`):
#   tmux new -s prueba
#   sh mantenimiento/probar-pipelines.sh <modo> [minutos]      # minutos por omision: 60
#
# Modos:
#   contenedores      crea y destruye contenedores con red bridge (veth + bridge + netns + overlayfs), 4 a la vez
#   contenedores-sin  lo mismo con --network none: si este aguanta y el de arriba cae, son las redes virtuales
#   disco             stress-ng machacando el NVMe (escritura/lectura mixta), sin red ni contenedores
#   rafagas           los 12 hilos al 100% 10 s y en reposo 10 s, en ciclo: picos de consumo como los de CI
#   ci                relanza corridas REALES de CI de PRs abiertos (sin despliegue) en los repos de SocioFit
#
# El log va a ~/pruebas-cuelgues/<fecha>-<modo>.log con sync por linea: si el server cae, dice hasta donde llego.
set -u

MODO="${1:-}"
MINUTOS="${2:-60}"
DIR="$HOME/pruebas-cuelgues"
mkdir -p "$DIR"
LOG="$DIR/$(date -u +%Y%m%dT%H%M%SZ)-${MODO:-sin-modo}.log"
FIN=$(( $(date +%s) + MINUTOS * 60 ))

anota() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; sync "$LOG"; }
queda_tiempo() { [ "$(date +%s)" -lt "$FIN" ]; }

ciclo_contenedores() {  # $1 = opciones de red para docker run
    docker image inspect alpine:3.22 >/dev/null 2>&1 || docker pull -q alpine:3.22 >>"$LOG"
    n=0
    while queda_tiempo; do
        for _ in 1 2 3 4; do docker run --rm $1 alpine:3.22 true >/dev/null 2>>"$LOG" & done
        wait
        n=$((n + 4))
        [ $((n % 200)) -eq 0 ] && anota "contenedores creados y destruidos: $n"
    done
    anota "total de contenedores: $n"
}

case "$MODO" in
    contenedores)
        anota "Inicio: contenedores con red bridge, $MINUTOS min"
        ciclo_contenedores ""
        ;;
    contenedores-sin)
        anota "Inicio: contenedores SIN red (--network none), $MINUTOS min"
        ciclo_contenedores "--network none"
        ;;
    disco)
        command -v stress-ng >/dev/null || { echo "Falta stress-ng: sudo apt install -y stress-ng" >&2; exit 1; }
        anota "Inicio: disco (stress-ng --hdd 4 --iomix 2) en $DIR, $MINUTOS min"
        stress-ng --hdd 4 --hdd-bytes 4G --iomix 2 --temp-path "$DIR" --timeout "${MINUTOS}m" --metrics-brief >>"$LOG" 2>&1
        anota "stress-ng termino con codigo $?"
        ;;
    rafagas)
        command -v stress-ng >/dev/null || { echo "Falta stress-ng: sudo apt install -y stress-ng" >&2; exit 1; }
        anota "Inicio: rafagas de CPU (10 s al 100%, 10 s en reposo), $MINUTOS min"
        n=0
        while queda_tiempo; do
            stress-ng --cpu 12 --timeout 10s --quiet
            sleep 10
            n=$((n + 1))
            [ $((n % 30)) -eq 0 ] && anota "rafagas: $n"
        done
        anota "total de rafagas: $n"
        ;;
    ci)
        # Solo corridas de pull_request: no despliegan nada. Relanza la ultima de cada PR abierto, en ciclo.
        anota "Inicio: CI real (re-run de PRs abiertos de SocioFit), $MINUTOS min"
        while queda_tiempo; do
            for repo in sociofit-webapi sociofit-webclient sociofit-appmobile; do
                gh run list -R "Raptor-Dev-Services/$repo" --event pull_request --limit 30 \
                    --json databaseId,headBranch,status -q '.[] | select(.status=="completed") | "\(.databaseId) \(.headBranch)"' \
                    | sort -u -k2,2 | head -4 | while read -r id rama; do
                        gh run rerun "$id" -R "Raptor-Dev-Services/$repo" >>"$LOG" 2>&1 && anota "relanzada $repo $rama ($id)"
                    done
            done
            # Esperar a que se vacie la cola antes de la siguiente tanda.
            while queda_tiempo && [ "$(for r in sociofit-webapi sociofit-webclient sociofit-appmobile; do gh run list -R "Raptor-Dev-Services/$r" --status in_progress --json databaseId -q length; gh run list -R "Raptor-Dev-Services/$r" --status queued --json databaseId -q length; done | awk '{s+=$1} END{print s+0}')" -gt 0 ]; do
                sleep 60
            done
        done
        ;;
    *)
        sed -n '2,20p' "$0"
        exit 1
        ;;
esac
anota "Fin del modo $MODO sin caida. Log: $LOG"
