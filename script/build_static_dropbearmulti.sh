#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/dropbear-static"
SRC_CACHE_DIR="$BUILD_DIR/src"
ARTIFACT_DIR="$BUILD_DIR/artifacts"

DROPBEAR_VER="${DROPBEAR_VER:-2025.89}"
DROPBEAR_TARBALL="dropbear-${DROPBEAR_VER}.tar.bz2"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/${DROPBEAR_TARBALL}"

JOBS="${JOBS:-$(nproc)}"
SIZE_CFLAGS="${SIZE_CFLAGS:--Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables}"
SIZE_LDFLAGS="${SIZE_LDFLAGS:--static -Wl,--gc-sections}"

NATIVE_CC="${NATIVE_CC:-musl-gcc}"
NATIVE_STRIP="${NATIVE_STRIP:-strip}"
AARCH64_CC="${AARCH64_CC:-aarch64-linux-musl-gcc}"
AARCH64_STRIP="${AARCH64_STRIP:-}"

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

fetch() {
  local url=$1
  local dest=$2

  if [[ ! -f "$dest" ]]; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  fi
}

static_link_works() {
  local cc=$1
  local ldflags=$2
  local extra_ldflags=$3
  local test_dir=$4
  local test_c="$test_dir/conftest.c"
  local test_bin="$test_dir/conftest"

  printf 'int main(void) { return 0; }\n' >"$test_c"

  # SIZE_CFLAGS/SIZE_LDFLAGS are shell-style flag lists by design.
  # shellcheck disable=SC2086
  "$cc" $SIZE_CFLAGS $ldflags $extra_ldflags "$test_c" -o "$test_bin" >/dev/null 2>&1
}

resolve_static_ldflags() {
  local target=$1
  local cc=$2
  local test_dir

  test_dir=$(mktemp -d "${TMPDIR:-/tmp}/dropbear-${target}-link.XXXXXX")

  if static_link_works "$cc" "$SIZE_LDFLAGS" "" "$test_dir"; then
    rm -rf "$test_dir"
    printf '%s\n' "$SIZE_LDFLAGS"
    return 0
  fi

  if static_link_works "$cc" "$SIZE_LDFLAGS" "-fno-link-libatomic" "$test_dir"; then
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
  local host_triplet
  local src_dir="$BUILD_DIR/dropbear-src-$target"
  local ldflags
  local configure_host=()

  require_tool "$cc"
  require_tool "$strip_tool"

  host_triplet=$(host_triplet_for_cc "$cc")
  if [[ -n "$host_triplet" ]]; then
    configure_host=(--host="$host_triplet")
  fi

  ldflags=$(resolve_static_ldflags "$target" "$cc")

  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar -xf "$SRC_CACHE_DIR/$DROPBEAR_TARBALL" -C "$src_dir" --strip-components=1

  pushd "$src_dir" >/dev/null
  make distclean >/dev/null 2>&1 || true

  CC="$cc" \
  CFLAGS="$SIZE_CFLAGS" \
  LDFLAGS="$ldflags" \
  ./configure \
    "${configure_host[@]}" \
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
  "$strip_tool" -s dropbearmulti
  popd >/dev/null

  install -Dm755 "$src_dir/dropbearmulti" "$ARTIFACT_DIR/$output_name"
  install -Dm755 "$src_dir/dropbearmulti" "$ROOT_DIR/$output_name"

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
require_tool bzip2
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

mkdir -p "$SRC_CACHE_DIR" "$ARTIFACT_DIR"
fetch "$DROPBEAR_URL" "$SRC_CACHE_DIR/$DROPBEAR_TARBALL"

build_target native dropbearmulti "$NATIVE_CC" "$NATIVE_STRIP"
build_target aarch64 dropbearmulti_aarch64 "$AARCH64_CC" "$AARCH64_STRIP"
