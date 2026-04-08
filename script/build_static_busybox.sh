#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/busybox-static"
SRC_CACHE_DIR="$BUILD_DIR/src"
SRC_DIR="$BUILD_DIR/busybox-src"
ARTIFACT_DIR="$BUILD_DIR/artifacts"

BUSYBOX_VER="${BUSYBOX_VER:-1.37.0}"
BUSYBOX_TARBALL="busybox-${BUSYBOX_VER}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TARBALL}"

JOBS="${JOBS:-$(nproc)}"
SIZE_CFLAGS="${SIZE_CFLAGS:--Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables}"
SIZE_LDFLAGS="${SIZE_LDFLAGS:--static -Wl,--gc-sections -s}"

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

config_set() {
  local key=$1
  local value=$2

  python - "$SRC_DIR/.config" "$key" "$value" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = config_path.read_text()
lines = text.splitlines()
out = []
matched = False

for line in lines:
    if line.startswith(f"{key}=") or line == f"# {key} is not set":
        matched = True
        if value == "n":
            out.append(f"# {key} is not set")
        else:
            out.append(f"{key}={value}")
    else:
        out.append(line)

if not matched:
    if value == "n":
        out.append(f"# {key} is not set")
    else:
        out.append(f"{key}={value}")

config_path.write_text("\n".join(out) + "\n")
PY
}

require_tool curl
require_tool tar
require_tool make
require_tool musl-gcc
require_tool strip
require_tool python
require_tool bzip2

mkdir -p "$SRC_CACHE_DIR" "$ARTIFACT_DIR"
fetch "$BUSYBOX_URL" "$SRC_CACHE_DIR/$BUSYBOX_TARBALL"

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
tar -xf "$SRC_CACHE_DIR/$BUSYBOX_TARBALL" -C "$SRC_DIR" --strip-components=1

pushd "$SRC_DIR" >/dev/null
make distclean >/dev/null 2>&1 || true

# Start from the broadest BusyBox feature set, then trim obvious build/debug bloat.
make allyesconfig

config_set CONFIG_STATIC y
config_set CONFIG_PIE n
config_set CONFIG_NOMMU n
config_set CONFIG_BUILD_LIBBUSYBOX n
config_set CONFIG_FEATURE_INDIVIDUAL n
config_set CONFIG_FEATURE_SHARED_BUSYBOX n
config_set CONFIG_DEBUG n
config_set CONFIG_DEBUG_PESSIMIZE n
config_set CONFIG_DEBUG_SANITIZE n
config_set CONFIG_UNIT_TEST n
config_set CONFIG_WERROR n
config_set CONFIG_WARN_SIMPLE_MSG n
config_set CONFIG_DMALLOC n
config_set CONFIG_EFENCE n
config_set CONFIG_NO_DEBUG_LIB n
config_set CONFIG_FEATURE_VERBOSE_USAGE n
config_set CONFIG_FEATURE_COMPRESS_USAGE n
config_set CONFIG_FEATURE_INSTALLER y
config_set CONFIG_INSTALL_APPLET_SYMLINKS y
config_set CONFIG_INSTALL_APPLET_HARDLINKS n
config_set CONFIG_INSTALL_APPLET_SCRIPT_WRAPPERS n
config_set CONFIG_LOCALE_SUPPORT n
config_set CONFIG_UNICODE_SUPPORT n
config_set CONFIG_FEDORA_COMPAT n
config_set CONFIG_FEATURE_CLEAN_UP n
config_set CONFIG_FEATURE_SUID n
config_set CONFIG_FEATURE_SUID_CONFIG n
config_set CONFIG_FEATURE_SUID_CONFIG_QUIET n
config_set CONFIG_FEATURE_EDITING_SAVEHISTORY n
config_set CONFIG_FEATURE_REVERSE_SEARCH n
config_set CONFIG_FEATURE_WTMP n
config_set CONFIG_FEATURE_UTMP n
config_set CONFIG_PAM n
config_set CONFIG_SELINUX n
config_set CONFIG_FEATURE_SEAMLESS_XZ n
config_set CONFIG_FEATURE_SEAMLESS_LZMA n
config_set CONFIG_FEATURE_SEAMLESS_BZ2 n
config_set CONFIG_FEATURE_2_4_MODULES n
config_set CONFIG_FEATURE_VI_REGEX_SEARCH n
config_set CONFIG_FEATURE_MOUNT_NFS n
config_set CONFIG_FEATURE_INETD_RPC n
config_set CONFIG_FEATURE_WGET_OPENSSL n
config_set CONFIG_DEVFSD n
config_set CONFIG_FEATURE_DEVFS n
config_set CONFIG_TC n
config_set CONFIG_FEATURE_TC_INGRESS n
config_set CONFIG_EXTRA_COMPAT n
config_set CONFIG_INCLUDE_SUSv2 n
config_set CONFIG_IOCTL_HEX2STR_ERROR n

# `yes` exits with SIGPIPE once oldconfig consumes enough input; temporarily
# disable pipefail so a successful oldconfig run doesn't abort the script.
set +o pipefail
yes "" | make oldconfig >/dev/null
set -o pipefail

export CC=musl-gcc
export HOSTCC=gcc
export HOSTCXX=g++
export EXTRA_CFLAGS="$SIZE_CFLAGS"
export EXTRA_LDFLAGS="$SIZE_LDFLAGS"

make -j"$JOBS" busybox
strip -s busybox
popd >/dev/null

install -Dm755 "$SRC_DIR/busybox" "$ARTIFACT_DIR/busybox"
install -Dm755 "$SRC_DIR/busybox" "$ROOT_DIR/busybox"

echo "Built static busybox:"
file "$ARTIFACT_DIR/busybox"
ls -lh "$ARTIFACT_DIR/busybox"
echo
echo "Applet count:"
"$ARTIFACT_DIR/busybox" --list | wc -l
