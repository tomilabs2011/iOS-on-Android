#!/bin/bash
# 02-prepare-phone.sh: install the two apps the phone needs and copy the setup files over.
#
# What it changes on the phone (all reversible with ./mac/03-undo.sh):
#   * installs Termux (a Linux terminal app) and AVNC (a screen viewer app)
#   * turns off Android's "phantom process killer", which would otherwise kill
#     the emulator a few minutes after you switch apps (a single settings value)
#   * copies this project into /sdcard/Download/ios-on-android/
#
# It does NOT root, flash, reboot, wipe, or touch the bootloader or any partition.
# It refuses to run unless 01-backup-phone.sh has finished for this phone.
#
# Usage: ./mac/02-prepare-phone.sh [--yes] [--any-device] [--skip-backup-check] [--keep-phantom-killer]

set -u
set -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ANY_DEVICE=0
SKIP_BACKUP_CHECK=0
FIX_PHANTOM=1
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --any-device) ANY_DEVICE=1 ;;
    --skip-backup-check) SKIP_BACKUP_CHECK=1 ;;
    --keep-phantom-killer) FIX_PHANTOM=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_macos
find_adb

step "1/6  Finding the phone"
select_device "$ANY_DEVICE"
print_device_summary

step "2/6  Checking there's a backup first (your rule)"
if [ "$SKIP_BACKUP_CHECK" = 1 ]; then
  warn "Backup check skipped on request."
else
  bk=$(find_backup_for_serial "$SERIAL")
  [ -n "$bk" ] || die "No finished backup of this phone on the Desktop. Run ./mac/01-backup-phone.sh first."
  ok "found $bk"
fi

step "3/6  Checking the phone can run this"
sdk=$(prop ro.build.version.sdk)
abi=$(prop ro.product.cpu.abi)
[ "$abi" = "arm64-v8a" ] || die "Expected a 64-bit ARM phone (arm64-v8a), got '$abi'."
[ "${sdk:-0}" -ge 24 ] || die "Android 7 or newer is required (this phone reports SDK $sdk)."
free_kb=$(dsh "df -k /data | tail -1" | awk '{print $4}')
if [ "${free_kb:-0}" -lt $((12 * 1024 * 1024)) ]; then
  die "The phone needs about 12 GB free for the build (has $((${free_kb:-0} / 1024 / 1024)) GB)."
fi
ok "arm64, Android SDK $sdk, $((free_kb / 1024 / 1024)) GB free"

step "4/6  Installing Termux and AVNC"
fetch_verified "$IOA_TERMUX_URL" "$IOA_CACHE/termux.apk" "$IOA_TERMUX_SHA256" || die "Couldn't download Termux."
fetch_verified "$IOA_AVNC_URL"   "$IOA_CACHE/avnc.apk"   "$IOA_AVNC_SHA256"   || die "Couldn't download AVNC."
ok "downloads verified (SHA-256)"

MANUAL_INSTALL=""
install_app() {   # $1 package, $2 apk, $3 nice name
  local out ver have
  have=$(dsh "pm list packages $1")
  if printf '%s\n' "$have" | grep -qx "package:$1"; then
    ver=$(dsh "dumpsys package $1" | sed -n 's/^ *versionName=//p' | head -1)
    ok "$3 is already installed (version $ver), keeping it"
    if [ "$1" = "com.termux" ]; then
      case "$ver" in
        0.10*|0.9*|0.8*|0.7*|0.6*)
          die "Your Termux ($ver) is the old, broken Google Play build. Uninstall it yourself (it may hold your files), then run this again." ;;
      esac
    fi
    return 0
  fi
  out=$("$ADB" -s "$SERIAL" install "$2" </dev/null 2>&1)
  if printf '%s' "$out" | grep -q Success; then
    ok "$3 installed"
    return 0
  fi
  warn "$3 didn't install over USB: $(printf '%s' "$out" | tail -1)"
  if printf '%s' "$out" | grep -q INSTALL_FAILED_USER_RESTRICTED; then
    warn "MIUI blocks USB installs until you enable Developer options > 'Install via USB'."
  fi
  dsh "mkdir -p $IOA_PHONE_DIR/apks" >/dev/null
  "$ADB" -s "$SERIAL" push "$2" "$IOA_PHONE_DIR/apks/" </dev/null >/dev/null
  MANUAL_INSTALL="$MANUAL_INSTALL $IOA_PHONE_DIR/apks/$(basename "$2")"
}
install_app com.termux      "$IOA_CACHE/termux.apk" "Termux"
install_app com.gaurav.avnc "$IOA_CACHE/avnc.apk"   "AVNC"

# Termux needs storage access to read the setup files from /sdcard.
for perm in READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
  dsh "pm grant com.termux android.permission.$perm" >/dev/null 2>&1 || true
done

step "5/6  Stopping Android from killing the emulator in the background"
mkdir -p "$IOA_STATE"
UNDO="$IOA_STATE/undo-$SERIAL.sh"
if [ "$FIX_PHANTOM" = 0 ]; then
  warn "Skipped. The emulator may get killed a few minutes after you leave Termux."
elif [ "$sdk" -ge 32 ]; then
  if [ ! -f "$UNDO" ]; then
    old=$(dsh "settings get global settings_enable_monitor_phantom_procs")
    echo "settings_enable_monitor_phantom_procs=$old" >"$UNDO"
  fi
  dsh "settings put global settings_enable_monitor_phantom_procs false" >/dev/null
  if [ "$(dsh "settings get global settings_enable_monitor_phantom_procs")" = "false" ]; then
    ok "phantom process killer disabled (Developer options also shows this as 'Disable child process restrictions')"
  else
    warn "MIUI refused the change. Enable Developer options > 'USB debugging (Security settings)' and run this again."
  fi
elif [ "$sdk" -eq 31 ]; then
  if [ ! -f "$UNDO" ]; then
    old=$(dsh "device_config get activity_manager max_phantom_processes")
    echo "max_phantom_processes=$old" >"$UNDO"
  fi
  dsh "device_config set_sync_disabled_for_tests persistent; device_config put activity_manager max_phantom_processes 2147483647" >/dev/null
  ok "phantom process limit raised (Android 12)"
else
  ok "not needed on Android $(prop ro.build.version.release)"
fi

step "6/6  Copying the setup files to the phone"
dsh "rm -rf $IOA_PHONE_DIR/android && mkdir -p $IOA_PHONE_DIR" >/dev/null
"$ADB" -s "$SERIAL" push "$IOA_ROOT/android" "$IOA_PHONE_DIR/" </dev/null >/dev/null || die "Copy failed."
"$ADB" -s "$SERIAL" push "$IOA_ROOT/config.env" "$IOA_PHONE_DIR/" </dev/null >/dev/null || die "Copy failed."
"$ADB" -s "$SERIAL" push "$IOA_ROOT/README.md" "$IOA_PHONE_DIR/" </dev/null >/dev/null || true
ok "copied to $IOA_PHONE_DIR"

if [ -n "$MANUAL_INSTALL" ]; then
  say ""
  say "${C_Y}Install these by hand on the phone (open the Files app > Downloads > ios-on-android > apks):${C_N}"
  for f in $MANUAL_INSTALL; do say "    $(basename "$f")"; done
  say "Then run this script again."
  exit 0
fi

dsh "am start -n com.termux/.app.TermuxActivity" >/dev/null 2>&1 || true

cat <<EOF

${C_B}Phone is ready.${C_N} Termux just opened on the phone. Two things to do there:

  1. MIUI battery saver kills background apps. On the phone, go to
     Settings > Apps > Manage apps > Termux > Battery saver > ${C_B}No restrictions${C_N}
     (and turn on ${C_B}Autostart${C_N} on the same page).

  2. In Termux, type this and press Enter (it takes 30-60 minutes, keep the
     phone plugged into a charger):

       ${C_B}bash $IOA_PHONE_DIR/android/setup.sh${C_N}

     If it says "Permission denied", run  termux-setup-storage  first, tap Allow, and retry.

You can unplug the phone from the Mac now.
EOF
