#!/bin/bash
# 01-backup-phone.sh: back up the Mi 10T Pro to the MacBook's Desktop.
#
# READ-ONLY on the phone: it only lists and copies files. Nothing on the phone is
# changed, installed, flashed or rebooted.
#
# What gets saved (in ~/Desktop/Mi10TPro-backup-<date>/):
#   sdcard/        everything in internal storage: photos, videos, downloads, music, documents...
#   apks/          the installer files of every app you installed yourself
#   device-info/   build/firmware details, partition list, settings, installed-app list
#   SHA256SUMS.txt a fingerprint of every file, to check the backup later
#   RESTORE.md     how to put things back
#
# What can't be saved without rooting the phone (which we won't do): app data
# like chats and game saves, SMS and call history. Nothing in this project erases
# or touches those. Your Google/Xiaomi account sync and WhatsApp's own backup cover them.
#
# Usage: ./mac/01-backup-phone.sh [--yes] [--any-device] [--dest DIR]

set -u
set -o pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

DEST_ROOT="$HOME/Desktop"
ANY_DEVICE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    --any-device) ANY_DEVICE=1 ;;
    --dest) shift; DEST_ROOT=${1:?--dest needs a folder} ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

# Prints "path|size" lines for regular files under ./$1, sorted. Works with
# macOS (BSD) stat and GNU stat.
local_manifest() {
  if stat -f '%z' / >/dev/null 2>&1; then
    find "$1" -type f -exec stat -f '%N|%z' {} + 2>/dev/null
  else
    find "$1" -type f -exec stat -c '%n|%s' {} + 2>/dev/null
  fi | LC_ALL=C sort
}

phone_manifest() {
  dsh "cd /sdcard && find $(rq "$1") -type f -exec stat -c '%n|%s' {} + 2>/dev/null" | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
step "1/7  Checking this Mac"
require_macos
[ -d "$DEST_ROOT" ] || die "Backup destination $DEST_ROOT doesn't exist."

if [ "${IOA_TEST_MODE:-0}" != 1 ]; then
  disk_dev=$(df "$DEST_ROOT" | awk 'NR==2 {print $1}')
  disk_info=$(diskutil info "$disk_dev" 2>/dev/null || true)
  if printf '%s\n' "$disk_info" | grep -Eq 'Device Location:[[:space:]]+External'; then
    die "$DEST_ROOT is on an external drive. You asked for the MacBook's internal SSD."
  elif printf '%s\n' "$disk_info" | grep -Eq 'Device Location:[[:space:]]+Internal|^[[:space:]]*Internal:[[:space:]]+Yes'; then
    ok "$DEST_ROOT is on the internal drive"
  else
    warn "Couldn't confirm which drive $DEST_ROOT is on, continuing."
  fi
  if printf '%s\n' "$disk_info" | grep -Eq 'Solid State:[[:space:]]+Yes'; then ok "it's an SSD"; fi
fi

# If "Desktop & Documents" iCloud sync is on, files on the Desktop get uploaded
# and can be evicted from the SSD ("Optimize Mac Storage"). A folder ending in
# .nosync is never synced, so the backup physically stays on the internal SSD.
NAME="Mi10TPro-backup-$(date +%Y-%m-%d_%H%M%S)"
ICLOUD_DESKTOP=0
if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Desktop" ] && [ "$DEST_ROOT" = "$HOME/Desktop" ]; then
  ICLOUD_DESKTOP=1
  NAME="$NAME.nosync"
  warn "iCloud 'Desktop & Documents' sync looks ON. The backup folder will be named"
  warn "'$NAME' so iCloud skips it and it stays on the internal SSD."
fi
BK="$DEST_ROOT/$NAME"

find_adb
ok "adb: $ADB ($("$ADB" version | head -1))"

# ---------------------------------------------------------------------------
step "2/7  Finding the phone"
select_device "$ANY_DEVICE"
print_device_summary

# ---------------------------------------------------------------------------
step "3/7  Measuring what needs to be copied"
need_kb=$(dsh "du -sk /sdcard/ 2>/dev/null" | awk 'END {print $1+0}')
avail_kb=$(df -k "$DEST_ROOT" | awk 'NR==2 {print $4}')
apk_kb=$((2 * 1024 * 1024))        # room for app installers (usually far less)
margin_kb=$((5 * 1024 * 1024))     # leave 5 GB free on the Mac
say "  Phone storage to copy: $((need_kb / 1024 / 1024)) GB (+ app installers)"
say "  Free on this Mac:      $((avail_kb / 1024 / 1024)) GB"
if [ "$avail_kb" -lt $((need_kb + apk_kb + margin_kb)) ]; then
  die "Not enough free space on the Mac. Free up about $(((need_kb + apk_kb + margin_kb - avail_kb) / 1024 / 1024 + 1)) GB and run this again."
fi
say "  USB 2 copies at roughly 30-40 MB/s, so expect about $((need_kb / 1024 / 35 / 60 + 1)) min. Keep the phone unlocked and plugged in."
confirm "Start the backup into $BK ?" || die "Cancelled, nothing was copied."

mkdir -p "$BK/device-info" "$BK/sdcard" "$BK/apks" || die "Couldn't create $BK"
if [ "$ICLOUD_DESKTOP" = 1 ]; then
  # Belt and braces for newer macOS iCloud (File Provider) builds.
  xattr -w 'com.apple.fileprovider.ignore#P' 1 "$BK" 2>/dev/null || true
fi
LOG_FILE="$BK/backup-log.txt"
_log "Backup of $SERIAL started $(date)"

# ---------------------------------------------------------------------------
step "4/7  Saving device information"
I="$BK/device-info"
dsh getprop                                  >"$I/getprop.txt"
dsh cat /proc/partitions                     >"$I/partitions.txt" 2>&1
dsh "ls -l /dev/block/by-name/ 2>&1"         >"$I/partitions-by-name.txt"
dsh "df -h 2>&1"                             >"$I/df.txt"
dsh "uname -a; cat /proc/cpuinfo | tail -5"  >"$I/kernel.txt"
dsh "pm list packages -f -U --user 0"        >"$I/packages-all.txt"
dsh "pm list packages -3"                    >"$I/packages-user-installed.txt"
for ns in global secure system; do
  dsh "settings list $ns"                    >"$I/settings-$ns.txt"
done
dsh "dumpsys battery"                        >"$I/battery.txt"
{
  echo "Device:      $(prop ro.product.model) / $(prop ro.product.device)"
  echo "Serial:      $SERIAL"
  echo "Android:     $(prop ro.build.version.release) (SDK $(prop ro.build.version.sdk))"
  echo "Build:       $(prop ro.build.display.id)"
  echo "Incremental: $(prop ro.build.version.incremental)"
  echo "Fingerprint: $(prop ro.build.fingerprint)"
  echo "Region:      $(prop ro.miui.region) $(prop ro.product.locale)"
  echo "Bootloader:  $(prop ro.boot.verifiedbootstate) / flash.locked=$(prop ro.boot.flash.locked)"
  echo
  echo "If the phone ever needs a full factory restore, download the official"
  echo "fastboot ROM that matches the 'Incremental' version above."
} >"$I/SUMMARY.txt"
ok "saved to device-info/ ($(wc -l <"$I/packages-user-installed.txt" | tr -d ' ') user-installed apps)"

# ---------------------------------------------------------------------------
step "5/7  Copying internal storage (this is the long part)"
FAILED=""
dsh "ls -1A /sdcard/" >"$I/sdcard-top-level.txt"
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  say "  -> $entry"
  if ! "$ADB" -s "$SERIAL" pull -a "/sdcard/$entry" "$BK/sdcard/" </dev/null; then
    warn "Some files in '$entry' could not be copied (details in the verify report)."
    FAILED="$FAILED|$entry"
  fi
done <"$I/sdcard-top-level.txt"

step "6/7  Copying app installers"
APK_FAIL=0
while IFS= read -r line; do
  pkg=${line#package:}
  [ -z "$pkg" ] && continue
  mkdir -p "$BK/apks/$pkg"
  dsh "pm path $(rq "$pkg")" | while IFS= read -r p; do
    p=${p#package:}
    [ -z "$p" ] && continue
    "$ADB" -s "$SERIAL" pull "$p" "$BK/apks/$pkg/" </dev/null >/dev/null 2>&1 || echo "FAIL $pkg $p" >>"$BK/apks/failed.txt"
  done
  say "  -> $pkg"
done <"$I/packages-user-installed.txt"
[ -f "$BK/apks/failed.txt" ] && APK_FAIL=$(wc -l <"$BK/apks/failed.txt" | tr -d ' ')

# ---------------------------------------------------------------------------
step "7/7  Verifying the copy against the phone"
REPORT="$BK/verify-report.txt"
: >"$REPORT"
TOTAL_MISSING=0
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  phone_manifest "$entry" >"$BK/.phone.tmp"
  (cd "$BK/sdcard" && local_manifest "$entry") >"$BK/.local.tmp"
  # Lines on the phone that are missing or a different size on the Mac:
  missing=$(LC_ALL=C comm -23 "$BK/.phone.tmp" "$BK/.local.tmp")
  n_phone=$(wc -l <"$BK/.phone.tmp" | tr -d ' ')
  if [ -n "$missing" ]; then
    n_miss=$(printf '%s\n' "$missing" | wc -l | tr -d ' ')
    TOTAL_MISSING=$((TOTAL_MISSING + n_miss))
    { echo "== $entry: $n_miss of $n_phone files missing or different size"; printf '%s\n' "$missing"; } >>"$REPORT"
    warn "$entry: $n_miss of $n_phone files didn't match"
  else
    echo "== $entry: all $n_phone files match" >>"$REPORT"
    ok "$entry ($n_phone files)"
  fi
done <"$I/sdcard-top-level.txt"
rm -f "$BK/.phone.tmp" "$BK/.local.tmp"

say "  Fingerprinting every file (SHA-256)..."
(cd "$BK" && find . -type f ! -name SHA256SUMS.txt ! -name backup-log.txt -print0 \
  | xargs -0 shasum -a 256 >SHA256SUMS.txt)

cat >"$BK/RESTORE.md" <<'EOF'
# Restoring this backup

Everything here was copied read-only; the phone was never modified by the backup.

* Check the backup is intact:  cd into this folder, then run  shasum -a 256 -c SHA256SUMS.txt
* Put photos/files back:       adb push sdcard/DCIM /sdcard/        (same for any folder)
* Reinstall an app:            adb install-multiple apks/<package>/*.apk
* Firmware details:            device-info/SUMMARY.txt (for picking the matching official ROM)

verify-report.txt lists any file that didn't copy (usually app-private files in Android/data).
EOF

{
  echo "serial=$SERIAL"
  echo "device=$(prop ro.product.device)"
  echo "date=$(date)"
  echo "missing_or_mismatched_files=$TOTAL_MISSING"
  echo "apk_failures=$APK_FAIL"
} >"$BK/BACKUP-COMPLETE.txt"

total_size=$(du -sh "$BK" | awk '{print $1}')
step "Backup finished: $BK ($total_size)"
if [ "$TOTAL_MISSING" -gt 0 ]; then
  warn "$TOTAL_MISSING file(s) couldn't be copied. See verify-report.txt."
  warn "That's usually app-private data under Android/data. Your photos and files are what matter: check the report."
else
  ok "every file on the phone's storage matches the copy on the Mac"
fi
[ "$APK_FAIL" -gt 0 ] && warn "$APK_FAIL app installer file(s) failed, see apks/failed.txt"
say ""
say "Next step:  ./mac/02-prepare-phone.sh"
