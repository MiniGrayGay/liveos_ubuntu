#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/openssh-static"
SRC_DIR="$BUILD_DIR/src"
OUT_DIR="$BUILD_DIR/out"
ARTIFACT_DIR="$BUILD_DIR/artifacts"
ROOTFS_DIR="$ROOT_DIR/rootfs"

OPENSSH_VER="${OPENSSH_VER:-10.3p1}"
OPENSSL_VER="${OPENSSL_VER:-3.6.1}"
ZLIB_VER="${ZLIB_VER:-1.3.2}"

OPENSSH_TARBALL="openssh-${OPENSSH_VER}.tar.gz"
OPENSSL_TARBALL="openssl-${OPENSSL_VER}.tar.gz"
ZLIB_TARBALL="zlib-${ZLIB_VER}.tar.gz"

OPENSSH_URL="https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${OPENSSH_TARBALL}"
OPENSSL_URL="https://www.openssl.org/source/${OPENSSL_TARBALL}"
ZLIB_URL="https://zlib.net/${ZLIB_TARBALL}"

JOBS="${JOBS:-$(nproc)}"
SIZE_CFLAGS="${SIZE_CFLAGS:--Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables}"
SIZE_LDFLAGS="${SIZE_LDFLAGS:--static -Wl,--gc-sections}"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

musl_static_link_works() {
  local extra_ldflags=$1
  local test_dir=$2
  local test_c="$test_dir/conftest.c"
  local test_bin="$test_dir/conftest"

  printf 'int main(void) { return 0; }\n' >"$test_c"

  # SIZE_CFLAGS/SIZE_LDFLAGS are shell-style flag lists by design.
  # shellcheck disable=SC2086
  musl-gcc $SIZE_CFLAGS $SIZE_LDFLAGS $extra_ldflags "$test_c" -o "$test_bin" >/dev/null 2>&1
}

fix_musl_static_link_flags() {
  local test_dir

  test_dir=$(mktemp -d "${TMPDIR:-/tmp}/sftp-musl-link.XXXXXX")

  if musl_static_link_works "" "$test_dir"; then
    rm -rf "$test_dir"
    return 0
  fi

  if musl_static_link_works "-fno-link-libatomic" "$test_dir"; then
    SIZE_LDFLAGS="$SIZE_LDFLAGS -fno-link-libatomic"
    echo "Added -fno-link-libatomic for musl-gcc static linking"
    rm -rf "$test_dir"
    return 0
  fi

  rm -rf "$test_dir"
  echo "musl-gcc cannot create a static executable with the configured flags" >&2
  echo "Try running: musl-gcc $SIZE_CFLAGS $SIZE_LDFLAGS /tmp/conftest.c -o /tmp/conftest" >&2
  return 1
}

fetch() {
  local url=$1
  local dest=$2

  if [[ ! -f "$dest" ]]; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  fi
}

unpack() {
  local tarball=$1
  local dest_dir=$2

  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  tar -xf "$tarball" -C "$dest_dir" --strip-components=1
}

require_tool curl
require_tool tar
require_tool make
require_tool musl-gcc
require_tool strip
require_tool mktemp

fix_musl_static_link_flags

mkdir -p "$SRC_DIR" "$OUT_DIR" "$ARTIFACT_DIR"

fetch "$OPENSSH_URL" "$SRC_DIR/$OPENSSH_TARBALL"
fetch "$OPENSSL_URL" "$SRC_DIR/$OPENSSL_TARBALL"
fetch "$ZLIB_URL" "$SRC_DIR/$ZLIB_TARBALL"

ZLIB_SRC="$BUILD_DIR/zlib-src"
OPENSSL_SRC="$BUILD_DIR/openssl-src"
OPENSSH_SRC="$BUILD_DIR/openssh-src"

unpack "$SRC_DIR/$ZLIB_TARBALL" "$ZLIB_SRC"
unpack "$SRC_DIR/$OPENSSL_TARBALL" "$OPENSSL_SRC"
unpack "$SRC_DIR/$OPENSSH_TARBALL" "$OPENSSH_SRC"

rm -rf "$OUT_DIR/zlib" "$OUT_DIR/openssl" "$OUT_DIR/openssh"
mkdir -p "$OUT_DIR/zlib" "$OUT_DIR/openssl" "$OUT_DIR/openssh"

pushd "$ZLIB_SRC" >/dev/null
make distclean >/dev/null 2>&1 || true
CC=musl-gcc \
CFLAGS="$SIZE_CFLAGS" \
LDFLAGS="$SIZE_LDFLAGS" \
./configure --static --prefix="$OUT_DIR/zlib"
make -j"$JOBS"
make install
popd >/dev/null

OPENSSL_PREFIX="$OUT_DIR/openssl"
OPENSSL_LIB_DIR="$OPENSSL_PREFIX/lib"

pushd "$OPENSSL_SRC" >/dev/null
make distclean >/dev/null 2>&1 || true
CC=musl-gcc \
AR=ar \
RANLIB=ranlib \
CFLAGS="$SIZE_CFLAGS" \
LDFLAGS="$SIZE_LDFLAGS" \
./Configure \
  linux-x86_64 \
  no-shared \
  no-tests \
  no-docs \
  no-module \
  no-async \
  no-engine \
  no-comp \
  no-secure-memory \
  --prefix="$OPENSSL_PREFIX" \
  --openssldir="$OPENSSL_PREFIX/ssl"
make -j"$JOBS"
make install_sw
popd >/dev/null

if [[ -d "$OPENSSL_PREFIX/lib64" && -f "$OPENSSL_PREFIX/lib64/libcrypto.a" ]]; then
  OPENSSL_LIB_DIR="$OPENSSL_PREFIX/lib64"
fi

pushd "$OPENSSH_SRC" >/dev/null
make distclean >/dev/null 2>&1 || true

export CC=musl-gcc
export CFLAGS="$SIZE_CFLAGS"
export CPPFLAGS="-I$OUT_DIR/zlib/include -I$OPENSSL_PREFIX/include"
export LDFLAGS="$SIZE_LDFLAGS -L$OUT_DIR/zlib/lib -L$OPENSSL_LIB_DIR"
export LIBS="$OPENSSL_LIB_DIR/libcrypto.a $OUT_DIR/zlib/lib/libz.a -lcrypt -lutil -lresolv"

./configure \
  --prefix=/usr \
  --sysconfdir=/etc/ssh \
  --libexecdir=/usr/lib/openssh \
  --with-privsep-path=/var/empty \
  --without-pam \
  --without-kerberos5 \
  --without-libedit \
  --without-security-key-builtin \
  --without-zlib-version-check \
  --disable-strip

make -j"$JOBS" sftp-server
strip -s sftp-server
popd >/dev/null

install -Dm755 "$OPENSSH_SRC/sftp-server" "$ARTIFACT_DIR/sftp-server"
install -Dm755 "$OPENSSH_SRC/sftp-server" "$ROOTFS_DIR/usr/lib/openssh/sftp-server"

mkdir -p "$ROOTFS_DIR/usr/local/crosware/software/dropbear/current/libexec"
ln -sfn /usr/lib/openssh/sftp-server \
  "$ROOTFS_DIR/usr/local/crosware/software/dropbear/current/libexec/sftp-server"

echo "Built static sftp-server:"
file "$ARTIFACT_DIR/sftp-server"
ls -lh "$ARTIFACT_DIR/sftp-server"
