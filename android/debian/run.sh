#!/bin/bash
# run.sh: starts the emulated iPod touch 2G running iPhone OS 3.1.3.
# Runs inside Debian; normally started by the `ios` command in Termux.
#
#   run.sh [--wifi] [--sound] [--headless]
#
# The screen is served over VNC on 127.0.0.1 (AVNC connects to it) and the
# QEMU monitor listens on 127.0.0.1 for the Home/Power button commands.

set -euo pipefail
# shellcheck source=../../config.env
. /opt/ios-on-android/config.env

W=/root/ios
FW=$W/firmware
QEMU=$W/qemu-system-arm
WIFI=0; SOUND=0; HEADLESS=0
for a in "$@"; do
  case "$a" in
    --wifi) WIFI=1 ;;
    --sound) SOUND=1 ;;
    --headless) HEADLESS=1 ;;
    *) echo "run.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

[ -x "$QEMU" ] || { echo "Emulator not built yet, run setup.sh" >&2; exit 1; }
[ -f "$FW/.nand-extracted" ] || { echo "Firmware not unpacked yet, run setup.sh" >&2; exit 1; }
mkdir -p "$W/device/nandrw" "$W/logs"

# nand=     read-only base image (stock iPhone OS 3.1.3)
# nandrw=   copy-on-write overlay holding everything the iPod writes
MACHINE="iPod-Touch,bootrom=$FW/$IOA_FW_BOOTROM,nor=$FW/$IOA_FW_NOR,nand=$FW/$IOA_FW_NAND_DIR,nandrw=$W/device/nandrw"

EXTRA=()
if [ "$WIFI" = 1 ]; then
  # The emulated BCM4325 Wi-Fi chip, backed by QEMU's user-mode network (NAT).
  MACHINE="$MACHINE,wifi=on"
  EXTRA+=(-netdev "user,id=wifi0,net=10.0.2.0/24,host=10.0.2.2,dhcpstart=10.0.2.15")
fi
if [ "$SOUND" = 1 ]; then
  # Termux's PulseAudio server, started by the `ios` command.
  EXTRA+=(-audio "driver=pa,server=127.0.0.1")
else
  EXTRA+=(-audio "driver=none")
fi
if [ "$HEADLESS" = 1 ]; then
  EXTRA+=(-display none)
else
  EXTRA+=(-display "vnc=127.0.0.1:$IOA_VNC_DISPLAY")
fi

echo "[run.sh] $(date) starting: wifi=$WIFI sound=$SOUND headless=$HEADLESS"
exec "$QEMU" \
  -M "$MACHINE" \
  -cpu max -m "$IOA_GUEST_RAM" \
  -monitor "tcp:127.0.0.1:$IOA_MONITOR_PORT,server=on,wait=off" \
  -serial "file:$W/logs/serial.log" \
  "${EXTRA[@]}"
