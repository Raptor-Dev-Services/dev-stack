#!/bin/sh
# Vigia de cuelgues del server: anota temperatura (CPU y NVMe), memoria, presion de memoria, carga y contenedores
# cada 5 s en /var/log/vigia.log, y fuerza la escritura a disco en cada linea para que la ultima
# sobreviva a un corte duro. Ver mantenimiento/CUELGUES.md.
while true; do
  t=$(sensors -u coretemp-isa-0000 2>/dev/null | awk '/temp1_input/{print $2; exit}')
  # NVMe: Composite (lo que el disco compara contra su max/crit) y el sensor mas caliente
  n=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nvme ] && echo "$(($(cat $h/temp1_input)/1000))/$(($(cat $h/temp3_input 2>/dev/null || echo 0)/1000))"; done)
  m=$(awk '/MemAvailable/{a=$2}/SwapTotal/{st=$2}/SwapFree/{sf=$2}END{printf "libre=%dMB swap=%dMB",a/1024,(st-sf)/1024}' /proc/meminfo)
  p=$(awk 'NR==1{print $2}' /proc/pressure/memory)
  echo "$(date -u +%FT%T) temp=$t $m psi_mem=$p carga=$(cut -d' ' -f1-3 /proc/loadavg) contenedores=$(docker ps -q | wc -l) nvme=$n" >> /var/log/vigia.log
  sync /var/log/vigia.log
  sleep 5
done
