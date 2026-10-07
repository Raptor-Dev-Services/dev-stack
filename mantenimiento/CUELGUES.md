# Cuelgues del server: investigacion abierta

**Estado al 2026-10-07 19:45 UTC: con el APST apagado volvio a caer (19:30, ver "19:30: cayo con el APST apagado"). El APST queda descartado; el NVMe como disco, no.** Antes se leyo como hardware/firmware; Dos caidas
nuevas con la instrumentacion puesta: una **en reposo** (load 0.1, 38 °C) y otra con carga media (load 18,
77 °C); ninguna dejo panic, lockup ni volcado de kdump. Ver "2026-10-07: lo que dijo la instrumentacion".

Equipo: Lenovo ThinkCentre `11MRS09W00` (placa `31A5`), Intel Core i5-11500, BIOS `M3JKT2FA` del
**2022-03-11**.
## El sintoma

El server (Ubuntu, kernel 7.0.0-34, i5 de 6 nucleos / 12 hilos, 30 GB de RAM, NVMe) **se congela sin
dejar nada en el log** y hay que reiniciarlo. El journal de cada arranque caido termina a media frase, sin
lineas de apagado, y al arrancar ext4 hace `orphan cleanup on readonly fs` y journald avisa
`system.journal corrupted or uncleanly shut down`.

| Arranque | Desde | Hasta | Como termino |
|---|---|---|---|
| -7 | 10-01 00:33 | 10-01 01:43 | apagado limpio (instalacion inicial) |
| -6 | 10-01 01:46 | 10-03 21:32 | apagado limpio, **2.5 dias estable** |
| -5 | 10-03 21:32 | 10-04 16:38 | **caida** |
| -4 | 10-04 16:50 | 10-04 21:58 | **caida** |
| -3 | 10-04 22:02 | 10-04 22:59 | **caida** |
| -2 | 10-04 23:01 | 10-05 07:04 | **caida** |
| -1 | 10-05 07:07 | 10-06 00:25 | **caida** |
| (siguiente) | 10-06 00:29 | 10-06 01:33 | reinicio LIMPIO (`systemd-reboot.service`): alguien corrio `reboot`, no fue caida |

Horas en UTC. Las ultimas lineas de cada arranque caido son de Docker desmontando un contenedor (veth,
overlayfs, buildkit), pero eso **no prueba nada**: hasta el 2026-10-06 journald escribia a disco cada 5 min,
asi que lo ultimo antes del corte se perdia.

## 2026-10-07: lo que dijo la instrumentacion

| Arranque | Termino | Ultima lectura del vigia | Volvio |
|---|---|---|---|
| 10-06 01:33 -> 11:0x | **caida en reposo** | 11:09:28 · 39 °C · 27.4 GB libres · load 0.10 · 37 contenedores | 11:10:27 (~1 min) |
| 10-06 11:10 -> 10-07 02:11 | **caida con CI** (rafaga de SocioRent) | 02:11:22 · 77 °C · 24.3 GB libres · load 18 · 40 contenedores | 02:27:31 (a mano) |

- El journal y el vigia se cortan **en el mismo segundo** (02:11:22): muerte instantanea, sin degradacion
  previa. Nada en el kernel: ni panic, ni soft/hard lockup, ni hung_task, ni MCE, ni NVMe.
- **kdump esta activo** (`kdump-tools` active, 512 MB reservados) y `/var/crash` solo tiene `kdump_lock`:
  no hubo kernel panic, porque un panic con kdump deja volcado. Con `nmi_watchdog=1` y
  `hardlockup_panic=1`, un CPU atorado tambien habria entrado en panic. **El kernel no se entero.**
- La caida en reposo **descarta carga y temperatura como causa**; la correlacion con CI era porque CI corre
  casi todo el dia. Pico de temperatura del 10-07: 85 °C a las 01:37, 34 min antes de caer, y sin caer.
- Lo que queda: **plataforma** (fuente de poder, RAM, placa) o **firmware/estados de reposo del CPU**
  (`intel_idle`, C-states hasta C3_ACPI; hay reportes de congelamientos de Rocket Lake en reposo profundo),
  agravado por un BIOS de 2022.

### Siguientes pasos, en orden (baratos y reversibles primero)

1. **Ver el aparato en la proxima caida:** apagado (fuente) o prendido y congelado (CPU/firmware/RAM).
   La caida en reposo volvio en ~1 min: si nadie lo reinicio, fue un reset de hardware.
2. **Limitar los C-states** como prueba: `intel_idle.max_cstate=1` en `GRUB_CMDLINE_LINUX_DEFAULT`
   (`/etc/default/grub`, `sudo update-grub`, reiniciar). Si deja de caerse por varios dias, era eso.
3. **Actualizar el BIOS** desde el soporte de Lenovo para el tipo `11MR` (el actual es de 2022-03).
4. **memtest86+** una noche (`sudo apt install memtest86+`, aparece en GRUB) y el diagnostico UEFI de
   Lenovo para RAM y fuente.

## 2026-10-07 02:38 UTC: prueba en curso, APST del NVMe apagado

Lo que el usuario ve en cada caida: **siempre con pipelines corriendo, el LED sigue encendido y al conectar
un monitor no da video**. La caida "en reposo" del 10-06 11:09 no cuadra con eso y no se uso para decidir.

**Hipotesis principal: el NVMe deja de responder bajo escritura pesada.** Es un Samsung PM961 OEM de 256 GB
(`MZVLW256HEHP-000L7`, firmware `5L7QCXB7`) con APST encendido (`default_ps_max_latency_us=100000`). Explica
que nunca quede log: el journal, el vigia y kdump escriben en el mismo disco que se muere.

Agravante encontrado: **el disco estaba al 100%** (93/98 GB; un dia antes, 57%): containerd 51 GB (imagenes
y cache de build) y `~/ci-runners` 24 GB. El usuario lo libero a 64%. Ademas el LV raiz solo tenia 100 GB de un VG de 235: el 2026-10-07 se extendio en caliente
(`lvextend -r -l +100%FREE`) a **232 GB, 29% usado**. El equipo es un ThinkCentre M90q Gen 2. Hasta encender la limpieza diaria
(`limpiar-docker.sh`, ver TODO.md), se vuelve a llenar.

**Cambio aplicado:** `/etc/default/grub.d/90-nvme-apst.cfg` agrega `nvme_core.default_ps_max_latency_us=0`;
`update-grub` y reinicio. Verificado tras el arranque: `/proc/cmdline` lo trae y el parametro vale `0`.
Para revertir: borrar ese archivo, `sudo update-grub` y reiniciar.

**Como se lee:** si pasan varios dias de pipelines sin caida, era el NVMe (y conviene cambiarlo por uno
nuevo de todas formas). Si vuelve a caer, siguen C-states (`intel_idle.max_cstate=1`), BIOS y memtest,
**de uno en uno**.

Notas del reinicio: Harbor no vuelve solo (sus contenedores mueren con `failed to initialize logging
driver: dial tcp 127.0.0.1:1514` porque arrancan antes que `harbor-log`); se levanta con
`docker compose up -d` en `~/Docker/harbor`. Y `hospital-core-api-staging` sale `unhealthy` porque su
healthcheck pega a `localhost:8080` y la API escucha en `127.0.0.1:8092`: la API esta bien, el
healthcheck esta mal (no es de este incidente).

## 2026-10-07 19:30 UTC: cayo con el APST apagado

| Arranque | Termino | Ultima lectura del vigia | Volvio |
|---|---|---|---|
| 10-07 02:39 -> 19:30 (~17 h) | **caida con CI** | 19:30:17 · 78 °C · 10.4 GB libres · swap 2.9 GB · load 30 · 42 contenedores | 19:33:51 |

- **El APST no era**: `/proc/cmdline` traia `nvme_core.default_ps_max_latency_us=0` y el parametro valia `0`.
  17 h de vida no prueban nada (antes hubo arranques de 24 h).
- Otra vez **nada en el kernel**: ni panic, ni lockup, ni hung_task, ni errores de NVMe/PCIe/AER, ni MCE;
  `/var/crash` y `pstore` vacios. El journal acaba en 19:30:14 en medio de Docker creando contenedores.
- **Primera caida con presion de memoria**: carga 30-58 sostenida desde ~18:47, swap 2.9 GB, `psi_mem` 22.6 a
  las 19:29:54. No es OOM (quedaban 8-12 GB libres), pero es la carga mas pesada que se ha visto al caer.
  El vigia ya iba lento al final: lineas cada 7-17 s en vez de 5 s, porque el `sync` por linea esperaba al disco.
- En vuelo: un `Android release` de `sociofit-appmobile` (Gradle, desde 19:15) y dos `Pipeline` de
  `sociofit-webapi` tras una rafaga de 6. **El Android release solo no es la causa**: hubo cinco antes sin
  caida (10-06 02:41, 13:55, 19:20; 10-07 02:59, 04:35).
- Temperatura de CPU normal (78-79 °C, pico del arranque 85 °C a las 02:46 sin caer).
- **El NVMe se calienta solo**: en reposo, 3 min despues de arrancar, el sensor 2 marca **60 °C** con
  `max` 68.85 / `crit` 71.85 en el Composite. Bajo 45 min de escritura de CI pudo llegar a su limite, y eso
  no lo media nadie. **Desde este commit el vigia anota `nvme=<composite>/<sensor2>` al final de la linea.**
- Entre tanto, unattended-upgrades instalo el kernel **7.0.0-38** (10-07 06:01); este arranque es el
  primero con el. Una variable mas: si deja de caerse, no se sabra si fue el kernel.

### Siguientes pasos

1. **Reinstalar el vigia** para que mida el NVMe: `sudo cp mantenimiento/vigia.sh /usr/local/bin/ && sudo systemctl restart vigia`.
2. **SMART del NVMe** (necesita sudo): `sudo smartctl -a /dev/nvme0`. Mirar `Warning/Critical Comp.
   Temperature Time`, `Media and Data Integrity Errors`, `Unsafe Shutdowns`, `Percentage Used` y el log de
   errores. Si los contadores de temperatura no estan en cero, el disco ha estado pasando de su limite.
3. **Bajar los picos**: de 4 a 2 runners (`actions-runner/compose.yaml`). Es mitigacion y es prueba a la vez.
4. Si el SMART sale limpio: C-states, BIOS y memtest, como dice la lista de arriba, de uno en uno.

## Lo que esta descartado, y con que

- **Regresion de kernel o de Docker:** el kernel 7.0.0-34, Docker 29.8 y containerd 2.3.6 se instalaron el
  10-01, y el server aguanto 2.5 dias con ellos. Del 10-01 al 10-04 solo se instalo openssl y `tree`
  (`/var/log/apt/history.log`).
- **Disco lleno:** 57% del raiz, inodos al 13%.
- **Memoria:** bajo una rafaga de CI completa (10-06 01:09, 6 corridas de SocioFit, load 52) el vigia
  registro como minimo **18 GB libres**, swap 4 MB y presion de memoria 0, escribiendo a disco cada 5 s.
  Tampoco hay OOM ni en el kernel ni en systemd-oomd en ningun arranque.
- **Ruido que NO es la causa:** los `ACPI BIOS Error ... AE_ALREADY_EXISTS` y `MMIO Stale Data` (firmware,
  salen en todo arranque), el `e1000e Interrupt Throttling Rate` (es la tarjeta de red, no calor), el
  `healthcheck failed ... only one connection allowed` de dockerd (sesion de BuildKit de un cliente de
  build) y `nvme0n1p2: Can't mount, would change RO state` (sale en todo apagado limpio).

## Lo que si se sabe

**Todas las caidas fueron con CI corriendo en el server.** Cruzado con `gh run list` de los repos de la
organizacion:

| Dia | Corridas de CI | Caidas |
|---|---|---|
| 10-03 | 26 | 0 |
| 10-04 | 251 | 3 |
| 10-05 | 201 | 1 |
| 10-06 (hasta 00:35) | 6 | 1 |

En cada caida habia jobs en vuelo que terminaron estirados, cancelados o fallidos (p. ej. un pipeline de
`sociofit-webapi` de 3-5 min que duro 07:02 -> 07:21 el 10-05). **Pero la carga sola no basta:** hubo horas
de CI sin caida (10-04 17:00-21:50), y la rafaga del 10-06 01:09 tambien se aguanto.

**La temperatura sube mucho bajo carga:** 86 °C de pico el 10-06 01:26 (umbral `high` 82, `crit` 100), sin
ningun aviso de throttling. En reposo esta en 39-45 °C. El 2026-10-01 se habian medido 71-75 °C (ver
`actions-runner/README.md`, "Recursos: CPU y disco").

## Hipotesis abiertas, en orden

1. **Hardware bajo picos sostenidos:** fuente de poder o RAM. Encaja con un corte sin una sola linea de log
   y con que pase solo tras horas de CI casi continuo.
2. **Temperatura** bajo carga larga: 86 °C en 15 min de rafaga; las caidas vinieron tras horas.
3. **Congelamiento del kernel** (lockup) que antes no dejaba rastro; con la instrumentacion de abajo, ahora
   deberia entrar en panic, registrarlo y reiniciarse solo a los 10 s.

## Instrumentacion instalada en el server (2026-10-06)

Todo esto vive **en el server, fuera de este repo** salvo el vigia, que esta versionado aqui:

| Que | Donde | Para que |
|---|---|---|
| journald escribe cada 10 s | `/etc/systemd/journald.conf.d/sync.conf` (`SyncIntervalSec=10s`) | que lo ultimo antes del corte no se pierda |
| panic ante lockup | `/etc/sysctl.d/99-cuelgues.conf` (`kernel.panic=10`, `softlockup_panic=1`, `hardlockup_panic=1`, `hung_task_panic=1`) | si es el kernel, se reinicia solo y deja el motivo |
| vigia | [`vigia.sh`](vigia.sh) en `/usr/local/bin/`, [`vigia.service`](vigia.service) habilitado | temp, memoria, presion, carga y contenedores cada 5 s en `/var/log/vigia.log`, con `sync` por linea |
| `lm-sensors` | paquete | `sensors` |

El journal ya era persistente (`/var/log/journal` existe; `journalctl --list-boots` muestra arranques viejos).

**Cuando se cierre la investigacion, quitarlo:** `SyncIntervalSec=10s` gasta escrituras al NVMe, y
`hung_task_panic=1` reinicia el server ante una tarea bloqueada >120 s, que en un disco lento puede ser un
falso positivo.

```sh
sudo systemctl disable --now vigia && sudo rm /etc/systemd/system/vigia.service /usr/local/bin/vigia.sh
sudo rm /etc/systemd/journald.conf.d/sync.conf /etc/sysctl.d/99-cuelgues.conf
sudo systemctl restart systemd-journald && sudo reboot   # el sysctl vuelve a su valor al reiniciar
```

## Cuando vuelva a caer

```sh
# 1. Confirmar que fue caida y no reinicio limpio: si al final sale "Reached target reboot.target", fue a mano
journalctl --list-boots | tail -3
journalctl -b -1 -n 40 --no-pager -o short-iso | cut -c1-200

# 2. El kernel del arranque caido (ahora con escritura cada 10 s)
journalctl -b -1 -k -p warning --no-pager | tail -30
journalctl -b -1 -k --no-pager | grep -iE "panic|lockup|hung_task|blocked for|oom|mce|hardware error|nvme"

# 3. Como estaba el server justo antes
tail -40 /var/log/vigia.log
awk '{t=$2;sub(/temp=/,"",t);f=$3;sub(/libre=/,"",f);sub(/MB/,"",f);c=$6;sub(/carga=/,"",c);
  if(t+0>mt){mt=t+0;wt=$1} if(mf==""||f+0<mf){mf=f+0;wf=$1} if(c+0>mc){mc=c+0;wc=$1}}
  END{print "temp max:",mt,"C a las",wt; print "libre min:",mf,"MB a las",wf; print "carga max:",mc,"a las",wc}' /var/log/vigia.log

# 4. Si hubo kernel panic con volcado
ls -la /var/lib/systemd/pstore /sys/fs/pstore 2>/dev/null
```

Como leerlo:

| Lo que se ve | Apunta a | Siguiente paso |
|---|---|---|
| Panic / lockup / hung_task en el kernel, y el server volvio solo a los ~10 s | kernel | buscar el mensaje; probar otro kernel desde GRUB ("Advanced options") |
| Vigia: `temp` subiendo hacia 90-100 °C en los ultimos minutos | calor | limpiar/ventilar la mini PC; bajar runners o hilos por build |
| Vigia: `libre` cayendo y `psi_mem` alto | memoria (hoy descartada, pero confirmar) | `mem_limit` a los runners |
| Todo normal hasta la ultima linea, nada en el kernel, y no volvio solo | hardware: fuente o RAM | `memtest86+` desde GRUB una noche; revisar fuente/eliminador |

**Pregunta que ayuda a separar:** tras cada caida, ¿el server estaba **apagado** (apunta a fuente/calor) o
**congelado con la luz encendida** (apunta a kernel/RAM)? Anotarlo en la tabla de arriba.

## Pendientes

- [ ] Esperar la proxima caida con la instrumentacion puesta y leerla con la seccion de arriba.
- [ ] Averiguar quien reinicio el 10-06 01:33 (`journalctl -b <n> _COMM=sudo`, `-u systemd-logind`;
      `grep -i automatic-reboot /etc/apt/apt.conf.d/50unattended-upgrades`).
- [ ] Opcional, en una ventana donde no estorbe tumbar staging: `stress-ng --cpu 0 --timeout 10m` (solo
      calor) y luego `stress-ng --vm 4 --vm-bytes 90% --timeout 10m` (solo memoria), mirando
      `watch -n5 'tail -1 /var/log/vigia.log'`.
- [ ] Mitigacion mientras tanto: bajar de 4 a 2 runners activos (`actions-runner/compose.yaml`) para
      reducir los picos.
- [ ] Al cerrar la investigacion: quitar la instrumentacion (bloque de arriba) y mover lo aprendido a
      `actions-runner/README.md`.
