#!/bin/bash
# 03-undo.sh: put the phone back the way it was before 02-prepare-phone.sh.
#
#   * restores the phantom-process setting to its original value
#   * removes /sdcard/Download/ios-on-android
#   * optionally uninstalls AVNC and Termux. Uninstalling Termux deletes
#     everything inside it, including the emulator and the emulated iPod's data.
#
# Your backup on the Desktop is never touched.
#
# Usage: ./mac/03-undo.sh [--yes] [--any-device]

set -u
set -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ANY_DEVICE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --any-device) ANY_DEVICE=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

require_macos
find_adb
step "Finding the phone"
select_device "$ANY_DEVICE"
print_device_summary

step "Restoring the background-process setting"
UNDO="$IOA_STATE/undo-$SERIAL.sh"
if [ -f "$UNDO" ]; then
  while IFS='=' read -r key val; do
    case "$key" in
      settings_enable_monitor_phantom_procs)
        if [ "$val" = "null" ] || [ -z "$val" ]; then
          dsh "settings delete global settings_enable_monitor_phantom_procs" >/dev/null
        else
          dsh "settings put global settings_enable_monitor_phantom_procs $(rq "$val")" >/dev/null
        fi ;;
      max_phantom_processes)
        if [ "$val" = "null" ] || [ -z "$val" ]; then
          dsh "device_config delete activity_manager max_phantom_processes" >/dev/null
        else
          dsh "device_config put activity_manager max_phantom_processes $(rq "$val")" >/dev/null
        fi
        dsh "device_config set_sync_disabled_for_tests none" >/dev/null ;;
    esac
  done <"$UNDO"
  rm -f "$UNDO"
  ok "restored"
else
  ok "nothing recorded for this phone, nothing to restore"
fi

step "Removing the copied setup files"
dsh "rm -rf $IOA_PHONE_DIR" >/dev/null
ok "removed $IOA_PHONE_DIR"

step "Apps"
if confirm "Uninstall AVNC?"; then
  "$ADB" -s "$SERIAL" uninstall com.gaurav.avnc </dev/null && ok "AVNC removed"
fi
if confirm "Uninstall Termux? This deletes the emulator and everything inside Termux."; then
  "$ADB" -s "$SERIAL" uninstall com.termux </dev/null && ok "Termux removed"
fi
say ""
say "Done. Android itself was never modified, so there's nothing else to undo."
