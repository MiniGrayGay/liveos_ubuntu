#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/openssh-static"
SRC_CACHE_DIR="$BUILD_DIR/src"
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

NATIVE_CC="${NATIVE_CC:-musl-gcc}"
NATIVE_STRIP="${NATIVE_STRIP:-strip}"
AARCH64_CC="${AARCH64_CC:-aarch64-linux-musl-gcc}"
AARCH64_STRIP="${AARCH64_STRIP:-}"
AARCH64_LINUX_HEADERS="${AARCH64_LINUX_HEADERS:-/usr/aarch64-linux-gnu/include}"

have_tool() {
  command -v "$1" >/dev/null 2>&1
}

install_package() {
  local package=$1

  if ! have_tool pacman; then
    return 1
  fi

  echo "Installing missing package: $package" >&2
  pacman -Sy --needed --noconfirm "$package"
}

require_tool() {
  local tool=$1
  local package=${2:-$1}

  if have_tool "$tool"; then
    return 0
  fi

  install_package "$package" || true

  if ! have_tool "$tool"; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

select_strip() {
  local cc=$1

  case "$cc" in
    aarch64-linux-musl-gcc)
      if [[ -n "$AARCH64_STRIP" ]]; then
        printf '%s\n' "$AARCH64_STRIP"
      elif have_tool aarch64-linux-musl-strip; then
        printf '%s\n' "aarch64-linux-musl-strip"
      elif have_tool aarch64-linux-gnu-strip; then
        printf '%s\n' "aarch64-linux-gnu-strip"
      else
        printf '%s\n' "strip"
      fi
      ;;
    *)
      printf '%s\n' "$NATIVE_STRIP"
      ;;
  esac
}

host_triplet_for_cc() {
  local cc=$1

  case "$cc" in
    aarch64-linux-musl-gcc) printf '%s\n' "aarch64-linux-musl" ;;
    aarch64-linux-gnu-gcc) printf '%s\n' "aarch64-linux-gnu" ;;
    *) printf '%s\n' "" ;;
  esac
}

openssl_target_for_cc() {
  local cc=$1

  case "$cc" in
    aarch64-*) printf '%s\n' "linux-aarch64" ;;
    *) printf '%s\n' "linux-x86_64" ;;
  esac
}

prepare_aarch64_musl_uapi_overlay() {
  local overlay="$BUILD_DIR/aarch64-musl-uapi"

  if [[ ! -d "$AARCH64_LINUX_HEADERS/linux" || ! -d "$AARCH64_LINUX_HEADERS/asm" ]]; then
    install_package aarch64-linux-gnu-linux-api-headers || true
  fi

  if [[ ! -d "$AARCH64_LINUX_HEADERS/linux" || ! -d "$AARCH64_LINUX_HEADERS/asm" ]]; then
    echo "Missing aarch64 Linux UAPI headers under $AARCH64_LINUX_HEADERS" >&2
    exit 1
  fi

  mkdir -p "$overlay"
  local uapi_dirs=(
    asm asm-generic cxl drm fwctl linux misc mtd nfs rdma regulator sound video xen
  )
  local dir
  for dir in "${uapi_dirs[@]}"; do
    if [[ -d "$AARCH64_LINUX_HEADERS/$dir" ]]; then
      ln -sfn "$AARCH64_LINUX_HEADERS/$dir" "$overlay/$dir"
    fi
  done

  printf '%s\n' "$overlay"
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

static_link_works() {
  local cc=$1
  local cflags=$2
  local ldflags=$3
  local extra_ldflags=$4
  local test_dir=$5
  local test_c="$test_dir/conftest.c"
  local test_bin="$test_dir/conftest"

  printf 'int main(void) { return 0; }\n' >"$test_c"

  # SIZE_CFLAGS/SIZE_LDFLAGS are shell-style flag lists by design.
  # shellcheck disable=SC2086
  "$cc" $cflags $ldflags $extra_ldflags "$test_c" -o "$test_bin" >/dev/null 2>&1
}

resolve_static_ldflags() {
  local target=$1
  local cc=$2
  local cflags=$3
  local test_dir

  test_dir=$(mktemp -d "${TMPDIR:-/tmp}/sftp-${target}-link.XXXXXX")

  if static_link_works "$cc" "$cflags" "$SIZE_LDFLAGS" "" "$test_dir"; then
    rm -rf "$test_dir"
    printf '%s\n' "$SIZE_LDFLAGS"
    return 0
  fi

  if static_link_works "$cc" "$cflags" "$SIZE_LDFLAGS" "-fno-link-libatomic" "$test_dir"; then
    rm -rf "$test_dir"
    echo "Added -fno-link-libatomic for $target static linking" >&2
    printf '%s\n' "$SIZE_LDFLAGS -fno-link-libatomic"
    return 0
  fi

  rm -rf "$test_dir"
  echo "$cc cannot create a static executable with the configured flags" >&2
  return 1
}

build_target() {
  local target=$1
  local output_name=$2
  local cc=$3
  local strip_tool=$4
  local install_native_rootfs=$5
  local host_triplet
  local openssl_target
  local configure_host=()
  local src_base="$BUILD_DIR/$target"
  local out_base="$OUT_DIR/$target"
  local zlib_src="$src_base/zlib-src"
  local openssl_src="$src_base/openssl-src"
  local openssh_src="$src_base/openssh-src"
  local zlib_prefix="$out_base/zlib"
  local openssl_prefix="$out_base/openssl"
  local openssl_lib_dir
  local cflags="$SIZE_CFLAGS"
  local ldflags
  local ar_tool=ar
  local ranlib_tool=ranlib

  require_tool "$cc"
  require_tool "$strip_tool"

  host_triplet=$(host_triplet_for_cc "$cc")
  openssl_target=$(openssl_target_for_cc "$cc")
  if [[ -n "$host_triplet" ]]; then
    configure_host=(--host="$host_triplet")
  fi

  if [[ "$target" == "aarch64" && "$cc" == "aarch64-linux-musl-gcc" ]]; then
    cflags="$cflags -isystem $(prepare_aarch64_musl_uapi_overlay)"
  fi

  ldflags=$(resolve_static_ldflags "$target" "$cc" "$cflags")

  rm -rf "$src_base" "$out_base"
  mkdir -p "$src_base" "$out_base"
  unpack "$SRC_CACHE_DIR/$ZLIB_TARBALL" "$zlib_src"
  unpack "$SRC_CACHE_DIR/$OPENSSL_TARBALL" "$openssl_src"
  unpack "$SRC_CACHE_DIR/$OPENSSH_TARBALL" "$openssh_src"

  pushd "$zlib_src" >/dev/null
  make distclean >/dev/null 2>&1 || true
  CC="$cc" \
  CFLAGS="$cflags" \
  LDFLAGS="$ldflags" \
  ./configure --static --prefix="$zlib_prefix"
  make -j"$JOBS"
  make install
  popd >/dev/null

  pushd "$openssl_src" >/dev/null
  make distclean >/dev/null 2>&1 || true
  CC="$cc" \
  AR="$ar_tool" \
  RANLIB="$ranlib_tool" \
  CFLAGS="$cflags" \
  LDFLAGS="$ldflags" \
  ./Configure \
    "$openssl_target" \
    no-shared \
    no-tests \
    no-docs \
    no-module \
    no-async \
    no-engine \
    no-comp \
    no-secure-memory \
    --prefix="$openssl_prefix" \
    --openssldir="$openssl_prefix/ssl"
  make -j"$JOBS"
  make install_sw
  popd >/dev/null

  openssl_lib_dir="$openssl_prefix/lib"
  if [[ -d "$openssl_prefix/lib64" && -f "$openssl_prefix/lib64/libcrypto.a" ]]; then
    openssl_lib_dir="$openssl_prefix/lib64"
  fi

  pushd "$openssh_src" >/dev/null
  make distclean >/dev/null 2>&1 || true

  CC="$cc" \
  CFLAGS="$cflags" \
  CPPFLAGS="-I$zlib_prefix/include -I$openssl_prefix/include" \
  LDFLAGS="$ldflags -L$zlib_prefix/lib -L$openssl_lib_dir" \
  LIBS="$openssl_lib_dir/libcrypto.a $zlib_prefix/lib/libz.a -lcrypt -lutil -lresolv" \
  ./configure \
    "${configure_host[@]}" \
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
  "$strip_tool" -s sftp-server
  popd >/dev/null

  install -Dm755 "$openssh_src/sftp-server" "$ARTIFACT_DIR/$output_name"
  install -Dm755 "$openssh_src/sftp-server" "$ROOT_DIR/$output_name"

  if [[ "$install_native_rootfs" == "yes" ]]; then
    install -Dm755 "$openssh_src/sftp-server" "$ROOTFS_DIR/usr/lib/openssh/sftp-server"

    mkdir -p "$ROOTFS_DIR/usr/local/crosware/software/dropbear/current/libexec"
    ln -sfn /usr/lib/openssh/sftp-server \
      "$ROOTFS_DIR/usr/local/crosware/software/dropbear/current/libexec/sftp-server"
  fi

  echo
  echo "Built static $output_name:"
  file "$ARTIFACT_DIR/$output_name"
  ls -lh "$ARTIFACT_DIR/$output_name"
  echo "ELF interpreter entries:"
  readelf -l "$ARTIFACT_DIR/$output_name" | grep -F INTERP || echo "  none"
}

require_tool curl
require_tool tar
require_tool make
require_tool readelf binutils
require_tool mktemp coreutils
require_tool "$NATIVE_CC" musl
require_tool "$NATIVE_STRIP" binutils
require_tool "$AARCH64_CC" musl-aarch64

AARCH64_STRIP="$(select_strip "$AARCH64_CC")"
if [[ "$AARCH64_STRIP" == aarch64-linux-gnu-strip ]]; then
  require_tool "$AARCH64_STRIP" aarch64-linux-gnu-binutils
else
  require_tool "$AARCH64_STRIP" binutils
fi

mkdir -p "$SRC_CACHE_DIR" "$OUT_DIR" "$ARTIFACT_DIR"

fetch "$OPENSSH_URL" "$SRC_CACHE_DIR/$OPENSSH_TARBALL"
fetch "$OPENSSL_URL" "$SRC_CACHE_DIR/$OPENSSL_TARBALL"
fetch "$ZLIB_URL" "$SRC_CACHE_DIR/$ZLIB_TARBALL"

build_target native sftp-server "$NATIVE_CC" "$NATIVE_STRIP" yes
build_target aarch64 sftp-server_aarch64 "$AARCH64_CC" "$AARCH64_STRIP" no
