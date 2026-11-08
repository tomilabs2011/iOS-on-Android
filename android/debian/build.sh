#!/bin/bash
# build.sh: runs inside the Debian userland (started by setup.sh).
# Builds qemu-system-arm with the iPod touch 2G machine and fetches iOS 3.1.3.
# Re-runnable: every step checks whether it's already done.

set -euo pipefail
# shellcheck source=../../config.env
. /opt/ios-on-android/config.env

W=/root/ios
SRC=$W/src
BUILD=$W/build
FW=$W/firmware
JOBS=${JOBS:-4}
mkdir -p "$W" "$FW" "$W/device" "$W/logs"

say() { printf '  %s\n' "$*"; }
die() { printf '\nSTOPPED (inside Debian): %s\n' "$*" >&2; exit 1; }

# ---- 1. build dependencies -------------------------------------------------
if [ ! -f "$W/.deps-done" ]; then
  say "Installing build tools (about 400 MB)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git xz-utils build-essential ninja-build pkg-config flex bison \
    python3 python3-venv python3-distlib \
    libglib2.0-dev libpixman-1-dev libssl-dev libslirp-dev libfdt-dev zlib1g-dev \
    libpng-dev libpulse-dev libavcodec-dev libavutil-dev
  touch "$W/.deps-done"
fi

# ---- 2. source, pinned to an exact commit -----------------------------------
if [ ! -d "$SRC/.git" ]; then
  say "Downloading emulator source ($IOA_EMU_TAG)..."
  rm -rf "$SRC"
  git clone --depth 1 --branch "$IOA_EMU_TAG" "$IOA_EMU_REPO" "$SRC"
fi
have=$(git -C "$SRC" rev-parse HEAD)
[ "$have" = "$IOA_EMU_COMMIT" ] \
  || die "Source is at $have but $IOA_EMU_COMMIT was expected. Delete $SRC and re-run."
say "Source verified at commit ${have:0:12}"

# ---- 3. configure + compile -------------------------------------------------
qemu_bin() { find "$BUILD" -maxdepth 2 -name qemu-system-arm -type f -perm -u+x 2>/dev/null | head -1; }

configure() {
  rm -rf "$BUILD"; mkdir -p "$BUILD"
  # Linux/Android has no CGL/EAGL, so the emulator's GL bridge compiles to a
  # stub and iOS draws with its own software renderer. Display goes out over VNC.
  (cd "$BUILD" && "$SRC/configure" \
    --target-list=arm-softmmu \
    --python=/usr/bin/python3 \
    --disable-docs --disable-werror --disable-capstone --disable-tools \
    --enable-vnc --enable-slirp \
    --extra-ldflags="-Wl,--no-as-needed -lcrypto") >"$W/logs/configure.log" 2>&1 \
    || { tail -40 "$W/logs/configure.log"; die "configure failed (full log: $W/logs/configure.log)"; }
}

compile() {
  say "Compiling with $JOBS jobs (15-40 minutes on a Snapdragon 865)..."
  ninja -C "$BUILD" -j "$JOBS" qemu-system-arm 2>&1 | tee "$W/logs/build.log" | grep -E '^\[[0-9]+/[0-9]+\]' | awk 'NR % 100 == 0' || true
  [ -n "$(qemu_bin)" ]
}

if [ -z "$(qemu_bin)" ] || [ ! -f "$W/.build-$IOA_EMU_COMMIT" ]; then
  configure
  if ! compile; then
    grep -E 'error|Error' "$W/logs/build.log" | head -20 || true
    # The only optional feature that is a likely source of trouble is the
    # FFmpeg video bridge. Retry once without it before giving up.
    say "Build failed, retrying without the FFmpeg video decoder..."
    apt-get remove -y libavcodec-dev libavutil-dev >/dev/null
    configure
    compile || { tail -40 "$W/logs/build.log"; die "Build failed (full log: $W/logs/build.log)"; }
  fi
  touch "$W/.build-$IOA_EMU_COMMIT"
fi
QEMU=$(qemu_bin)
ln -sf "$QEMU" "$W/qemu-system-arm"
"$QEMU" -M help >"$W/logs/machines.txt" 2>&1 || true
grep -q '^iPod-Touch ' "$W/logs/machines.txt" || die "The build has no iPod-Touch machine."
say "Emulator built: $QEMU"

# ---- 4. firmware --------------------------------------------------------------
fetch() {   # name sha256
  local f="$FW/$1"
  if [ -f "$f" ] && echo "$2  $f" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
  say "Downloading $1..."
  curl -fL --retry 5 --connect-timeout 20 -C - -o "$f.part" "$IOA_FW_URL/$1" || die "Download of $1 failed."
  echo "$2  $f.part" | sha256sum -c --quiet - || { rm -f "$f.part"; die "$1 failed its checksum, deleted. Re-run to retry."; }
  mv "$f.part" "$f"
}
fetch "$IOA_FW_BOOTROM" "$IOA_FW_BOOTROM_SHA256"
fetch "$IOA_FW_NOR" "$IOA_FW_NOR_SHA256"
fetch "$IOA_FW_NAND" "$IOA_FW_NAND_SHA256"
say "Firmware verified (SHA-256)"

if [ ! -f "$FW/.nand-extracted" ]; then
  say "Unpacking the iPod's flash image (255,000 small files, a few minutes)..."
  if [ -d "$FW/$IOA_FW_NAND_DIR" ]; then chmod -R u+w "$FW/$IOA_FW_NAND_DIR"; rm -rf "${FW:?}/$IOA_FW_NAND_DIR"; fi
  # The archive was made on a Mac: skip its AppleDouble (._*) and .DS_Store files.
  tar --warning=no-unknown-keyword --exclude='._*' --exclude='.DS_Store' \
    -xzf "$FW/$IOA_FW_NAND" -C "$FW"
  for cs in cs0 cs1 cs2 cs3; do
    [ -d "$FW/$IOA_FW_NAND_DIR/$cs" ] || die "Unpacked image is missing $cs."
  done
  # The base image stays read-only; the iPod's own writes go to an overlay
  # (device/nandrw), so a factory reset is just deleting that folder.
  chmod -R a-w "$FW/$IOA_FW_NAND_DIR"
  touch "$FW/.nand-extracted"
fi
say "iOS $IOA_IOS_VERSION ($IOA_IOS_BUILD) ready"
