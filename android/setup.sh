#!/data/data/com.termux/files/usr/bin/bash
# setup.sh: runs INSIDE TERMUX on the phone.
#
#   bash /sdcard/Download/ios-on-android/android/setup.sh
#
# 1. installs a Debian Linux userland inside Termux (proot: no root needed)
# 2. builds the iPod touch 2G emulator from source inside it
# 3. downloads iPhone OS 3.1.3 and checks it against pinned SHA-256 sums
# 4. installs the `ios` command
#
# Everything lives inside Termux's private app folder. Android itself, its
# partitions and the bootloader are never touched. Safe to re-run: finished
# steps are skipped.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=../config.env
. "$REPO/config.env"

B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$N" "$*"; }
die()  { printf '\n%sSTOPPED:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

STATE="$HOME/.ios-on-android"
mkdir -p "$STATE"
exec > >(tee -a "$STATE/setup.log") 2>&1
echo "---- setup started $(date)"

step "1/5  Checking the phone"
[ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ] && command -v pkg >/dev/null \
  || die "Run this inside the Termux app."
[ "$(uname -m)" = "aarch64" ] || die "Needs a 64-bit ARM phone, this is $(uname -m)."
free_kb=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
[ "$free_kb" -ge $((10 * 1024 * 1024)) ] \
  || die "Needs about 10 GB free inside Termux, only $((free_kb / 1024 / 1024)) GB available."
ok "aarch64, $((free_kb / 1024 / 1024)) GB free"
command -v termux-wake-lock >/dev/null && termux-wake-lock || true   # keep CPU awake during the build

step "2/5  Updating Termux and installing tools"
export DEBIAN_FRONTEND=noninteractive
pkg update -y
pkg upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
pkg install -y proot-distro netcat-openbsd pulseaudio termux-tools
ok "tools installed"

step "3/5  Installing Debian (inside Termux, no root)"
if proot-distro login debian -- true >/dev/null 2>&1; then
  ok "Debian already installed"
else
  proot-distro install debian
  ok "Debian installed"
fi
# Copy the Debian-side scripts and the pinned config into the Debian userland.
tar -C "$HERE/debian" -cf - . | proot-distro login debian -- \
  bash -c 'rm -rf /opt/ios-on-android && mkdir -p /opt/ios-on-android && tar -C /opt/ios-on-android -xf -'
proot-distro login debian -- bash -c 'cat > /opt/ios-on-android/config.env' <"$REPO/config.env"
proot-distro login debian -- chmod 755 /opt/ios-on-android/build.sh /opt/ios-on-android/run.sh

step "4/5  Building the emulator and downloading iOS $IOA_IOS_VERSION (the long part)"
# 4 parallel jobs keeps memory use sane; set JOBS=8 to go faster on a cool phone.
proot-distro login debian -- env JOBS="${JOBS:-4}" /opt/ios-on-android/build.sh

step "5/5  Installing the 'ios' command"
install -m 755 "$HERE/termux/ios" "$PREFIX/bin/ios"
cp "$REPO/config.env" "$STATE/config.env"
ok "installed $PREFIX/bin/ios"

cat <<EOF

${B}All set.${N} To start iOS, type:

    ${B}ios${N}

The AVNC app opens and shows the iPod screen. The first boot takes a few
minutes (black screen, then the Apple logo). Type  ${B}ios help${N}  for buttons,
screenshots, the self-test and uninstalling.
EOF
command -v termux-wake-unlock >/dev/null && termux-wake-unlock || true
