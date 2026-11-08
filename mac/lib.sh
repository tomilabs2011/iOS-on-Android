# shellcheck shell=bash
# Shared helpers for the Mac-side scripts. Written for the bash 3.2 that ships
# with macOS (no associative arrays, no ${var,,}, no mapfile).

IOA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
. "$IOA_ROOT/config.env"

IOA_MAC_DIR="$IOA_ROOT/mac"
IOA_CACHE="$IOA_MAC_DIR/.cache"
IOA_STATE="$IOA_MAC_DIR/.state"

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_N=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_N=""
fi

LOG_FILE=""
ASSUME_YES=0
ADB=""
SERIAL=""

_log() { if [ -n "$LOG_FILE" ]; then printf '%s\n' "$*" >>"$LOG_FILE"; fi; }
say()  { printf '%s\n' "$*"; _log "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_N"; _log ""; _log "==> $*"; }
ok()   { printf '%s  ok%s  %s\n' "$C_G" "$C_N" "$*"; _log "  ok  $*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_Y" "$C_N" "$*" >&2; _log "WARNING: $*"; }
die()  { printf '\n%sSTOPPED:%s %s\n' "$C_R" "$C_N" "$*" >&2; _log "STOPPED: $*"; exit 1; }

confirm() {
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  local a
  printf '%s [y/N] ' "$1"
  read -r a </dev/tty || return 1
  case "$a" in y|Y|yes|YES|Yes) return 0 ;; esac
  return 1
}

# Quote a string for the phone's shell (adb shell re-parses its arguments).
rq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

require_macos() {
  if [ "${IOA_TEST_MODE:-0}" = 1 ]; then return 0; fi
  [ "$(uname -s)" = "Darwin" ] || die "This script is meant to run on your MacBook (macOS)."
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# Download $1 to $2 and check it against SHA-256 $3. Keeps a verified copy.
fetch_verified() {
  local url=$1 out=$2 want=$3 got
  if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$want" ]; then return 0; fi
  mkdir -p "$(dirname "$out")"
  curl -fL --retry 4 --connect-timeout 20 -o "$out.part" "$url" || { rm -f "$out.part"; return 1; }
  got=$(sha256_of "$out.part")
  if [ "$got" != "$want" ]; then
    rm -f "$out.part"
    warn "Checksum mismatch for $(basename "$out"): expected $want, got $got"
    return 1
  fi
  mv "$out.part" "$out"
}

find_adb() {
  if command -v adb >/dev/null 2>&1; then ADB=$(command -v adb); return 0; fi
  local local_adb="$IOA_MAC_DIR/.tools/platform-tools/adb"
  if [ -x "$local_adb" ]; then ADB=$local_adb; return 0; fi
  say "adb (Google's official Android USB tool) isn't installed on this Mac."
  if command -v brew >/dev/null 2>&1; then
    say "You can install it with:  brew install --cask android-platform-tools"
  fi
  confirm "Download Google's platform-tools (about 15 MB) into this project folder instead?" \
    || die "adb is required. Install it, then run this again."
  mkdir -p "$IOA_MAC_DIR/.tools"
  curl -fL --retry 4 -o "$IOA_MAC_DIR/.tools/platform-tools.zip" "$IOA_PLATFORM_TOOLS_URL" \
    || die "Couldn't download platform-tools."
  (cd "$IOA_MAC_DIR/.tools" && unzip -q -o platform-tools.zip) || die "Couldn't unzip platform-tools."
  [ -x "$local_adb" ] || die "platform-tools downloaded but adb is missing."
  ADB=$local_adb
}

# Run a command on the phone. stdin is closed so adb can't swallow the input
# of a surrounding `while read` loop. Carriage returns are stripped.
dsh() { "$ADB" -s "$SERIAL" shell "$@" </dev/null | tr -d '\r'; }
prop() { dsh getprop "$1"; }

is_target_codename() {
  local c
  for c in $IOA_DEVICE_CODENAMES; do [ "$1" = "$c" ] && return 0; done
  return 1
}

# Finds the Mi 10T Pro among connected devices and sets SERIAL.
# With $1 = 1, accepts any single connected device.
select_device() {
  local any=${1:-0} waited=0 told=0 serials unauth s code chosen count
  "$ADB" start-server >/dev/null 2>&1
  while :; do
    serials=$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
    unauth=$("$ADB" devices | awk 'NR>1 && $2=="unauthorized" {print $1}')
    if [ -n "$serials" ]; then break; fi
    if [ -n "$unauth" ] && [ $told -lt 2 ]; then
      say "The phone is connected but hasn't trusted this Mac yet."
      say "Unlock the phone and tap 'Allow' on the USB debugging prompt (tick 'Always allow')."
      told=2
    elif [ $told -eq 0 ]; then
      say "Waiting for the phone... Plug it in by USB with USB debugging turned on."
      say "(Settings > About phone > tap 'MIUI version' 7 times, then"
      say " Settings > Additional settings > Developer options > USB debugging.)"
      told=1
    fi
    sleep 2
    waited=$((waited + 2))
    [ $waited -ge 300 ] && die "No authorized phone found after 5 minutes."
  done

  chosen=""; count=0
  for s in $serials; do
    count=$((count + 1))
    code=$("$ADB" -s "$s" shell getprop ro.product.device </dev/null | tr -d '\r')
    if is_target_codename "$code"; then chosen=$s; break; fi
  done
  if [ -z "$chosen" ]; then
    if [ "$any" = 1 ] && [ $count -eq 1 ]; then
      chosen=$serials
      warn "This doesn't look like a $IOA_DEVICE_NAME, continuing because of --any-device."
    else
      say "Connected device(s):"
      "$ADB" devices -l | sed 1d
      die "No $IOA_DEVICE_NAME found (looked for codename: $IOA_DEVICE_CODENAMES). If you have the Galaxy A5 plugged in too, this project deliberately ignores it."
    fi
  fi
  SERIAL=$chosen
  export ANDROID_SERIAL=$SERIAL
}

print_device_summary() {
  say "  Model:        $(prop ro.product.manufacturer) $(prop ro.product.model) ($(prop ro.product.device))"
  say "  Android:      $(prop ro.build.version.release) (SDK $(prop ro.build.version.sdk))"
  say "  Build:        $(prop ro.build.display.id)"
  say "  MIUI/HyperOS: $(prop ro.miui.ui.version.name) $(prop ro.build.version.incremental)"
  say "  Bootloader:   verified-boot state '$(prop ro.boot.verifiedbootstate)' (orange = unlocked)"
  say "  Serial:       $SERIAL"
}

# Most recent completed backup folder for this phone, or empty.
find_backup_for_serial() {
  local d last=""
  for d in "$HOME"/Desktop/Mi10TPro-backup-*; do
    [ -f "$d/BACKUP-COMPLETE.txt" ] || continue
    grep -q "^serial=$1\$" "$d/BACKUP-COMPLETE.txt" && last=$d
  done
  printf '%s' "$last"
}
