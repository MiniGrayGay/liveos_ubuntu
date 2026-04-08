#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/dropbear-static"
SRC_CACHE_DIR="$BUILD_DIR/src"
SRC_DIR="$BUILD_DIR/dropbear-src"
ARTIFACT_DIR="$BUILD_DIR/artifacts"

DROPBEAR_VER="${DROPBEAR_VER:-2025.89}"
DROPBEAR_TARBALL="dropbear-${DROPBEAR_VER}.tar.bz2"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/${DROPBEAR_TARBALL}"

JOBS="${JOBS:-$(nproc)}"
SIZE_CFLAGS="${SIZE_CFLAGS:--Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables}"
SIZE_LDFLAGS="${SIZE_LDFLAGS:--static -Wl,--gc-sections}"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

fetch() {
  local url=$1
  local dest=$2

  if [[ ! -f "$dest" ]]; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  fi
}

require_tool curl
require_tool tar
require_tool make
require_tool musl-gcc
require_tool strip
require_tool bzip2

mkdir -p "$SRC_CACHE_DIR" "$ARTIFACT_DIR"
fetch "$DROPBEAR_URL" "$SRC_CACHE_DIR/$DROPBEAR_TARBALL"

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
tar -xf "$SRC_CACHE_DIR/$DROPBEAR_TARBALL" -C "$SRC_DIR" --strip-components=1

pushd "$SRC_DIR" >/dev/null
make distclean >/dev/null 2>&1 || true

export CC=musl-gcc
export CFLAGS="$SIZE_CFLAGS"
export LDFLAGS="$SIZE_LDFLAGS"

./configure \
  --disable-zlib \
  --disable-pam \
  --disable-lastlog \
  --disable-utmp \
  --disable-utmpx \
  --disable-wtmp \
  --disable-wtmpx \
  --disable-pututline \
  --enable-static

make PROGRAMS='dropbear dbclient dropbearkey dropbearconvert scp' MULTI=1 SCPPROGRESS=0 -j"$JOBS"
strip -s dropbearmulti
popd >/dev/null

install -Dm755 "$SRC_DIR/dropbearmulti" "$ARTIFACT_DIR/dropbearmulti"
install -Dm755 "$SRC_DIR/dropbearmulti" "$ROOT_DIR/dropbearmulti"

echo "Built static dropbearmulti:"
file "$ARTIFACT_DIR/dropbearmulti"
ls -lh "$ARTIFACT_DIR/dropbearmulti"
