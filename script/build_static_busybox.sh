#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/busybox-static"
SRC_CACHE_DIR="$BUILD_DIR/src"
ARTIFACT_DIR="$BUILD_DIR/artifacts"

BUSYBOX_VER="${BUSYBOX_VER:-1.38.0}"
BUSYBOX_TARBALL="busybox-${BUSYBOX_VER}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TARBALL}"

JOBS="${JOBS:-$(nproc)}"
SIZE_CFLAGS="${SIZE_CFLAGS:--Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables}"
SIZE_LDFLAGS="${SIZE_LDFLAGS:--static -Wl,--gc-sections -s}"

NATIVE_CC="${NATIVE_CC:-musl-gcc}"
NATIVE_STRIP="${NATIVE_STRIP:-strip}"
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

select_aarch64_cc() {
  if [[ -n "${AARCH64_CC:-}" ]]; then
    require_tool "$AARCH64_CC"
    printf '%s\n' "$AARCH64_CC"
    return 0
  fi

  if have_tool aarch64-linux-musl-gcc; then
    printf '%s\n' "aarch64-linux-musl-gcc"
    return 0
  fi

  if ! have_tool aarch64-linux-gnu-gcc; then
    install_package aarch64-linux-gnu-gcc || true
  fi

  if have_tool aarch64-linux-gnu-gcc; then
    printf '%s\n' "aarch64-linux-gnu-gcc"
    return 0
  fi

  echo "Missing aarch64 cross compiler: aarch64-linux-musl-gcc or aarch64-linux-gnu-gcc" >&2
  exit 1
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
    aarch64-linux-gnu-gcc)
      printf '%s\n' "${AARCH64_STRIP:-aarch64-linux-gnu-strip}"
      ;;
    *)
      printf '%s\n' "$NATIVE_STRIP"
      ;;
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

config_set() {
  local config_path=$1
  local key=$2
  local value=$3
  local tmp="${config_path}.tmp"

  awk -v key="$key" -v value="$value" '
    BEGIN {
      replacement = (value == "n") ? "# " key " is not set" : key "=" value
    }
    $0 == "# " key " is not set" || index($0, key "=") == 1 {
      if (!matched) {
        print replacement
        matched = 1
      }
      next
    }
    { print }
    END {
      if (!matched) {
        print replacement
      }
    }
  ' "$config_path" >"$tmp"
  mv "$tmp" "$config_path"
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

  test_dir=$(mktemp -d "${TMPDIR:-/tmp}/busybox-${target}-link.XXXXXX")

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
  echo "Try running: $cc $SIZE_CFLAGS $SIZE_LDFLAGS /tmp/conftest.c -o /tmp/conftest" >&2
  return 1
}

prepare_config() {
  local src_dir=$1
  local config_path="$src_dir/.config"

  pushd "$src_dir" >/dev/null
  make distclean >/dev/null 2>&1 || true

  # Select the broadest BusyBox feature set first. The overrides below keep the
  # result as one static executable and remove debug/external-library bloat.
  if ! make allyesconfig >"$src_dir/allyesconfig.log" 2>&1; then
    cat "$src_dir/allyesconfig.log" >&2
    exit 1
  fi
  popd >/dev/null

  config_set "$config_path" CONFIG_STATIC y
  config_set "$config_path" CONFIG_PIE n
  config_set "$config_path" CONFIG_NOMMU n
  config_set "$config_path" CONFIG_BUILD_LIBBUSYBOX n
  config_set "$config_path" CONFIG_FEATURE_INDIVIDUAL n
  config_set "$config_path" CONFIG_FEATURE_SHARED_BUSYBOX n
  config_set "$config_path" CONFIG_DEBUG n
  config_set "$config_path" CONFIG_DEBUG_PESSIMIZE n
  config_set "$config_path" CONFIG_DEBUG_SANITIZE n
  config_set "$config_path" CONFIG_UNIT_TEST n
  config_set "$config_path" CONFIG_WERROR n
  config_set "$config_path" CONFIG_WARN_SIMPLE_MSG n
  config_set "$config_path" CONFIG_DMALLOC n
  config_set "$config_path" CONFIG_EFENCE n
  config_set "$config_path" CONFIG_NO_DEBUG_LIB n
  config_set "$config_path" CONFIG_FEATURE_VERBOSE_USAGE n
  config_set "$config_path" CONFIG_FEATURE_INSTALLER y
  config_set "$config_path" CONFIG_INSTALL_APPLET_SYMLINKS y
  config_set "$config_path" CONFIG_INSTALL_APPLET_HARDLINKS n
  config_set "$config_path" CONFIG_INSTALL_APPLET_SCRIPT_WRAPPERS n
  config_set "$config_path" CONFIG_FEATURE_CLEAN_UP n
  config_set "$config_path" CONFIG_FEATURE_SUID n
  config_set "$config_path" CONFIG_FEATURE_SUID_CONFIG n
  config_set "$config_path" CONFIG_FEATURE_SUID_CONFIG_QUIET n
  config_set "$config_path" CONFIG_FEATURE_EDITING_SAVEHISTORY n
  config_set "$config_path" CONFIG_FEATURE_REVERSE_SEARCH n
  config_set "$config_path" CONFIG_FEATURE_WTMP n
  config_set "$config_path" CONFIG_FEATURE_UTMP n

  # These features pull in external libraries or external executables, which
  # works against the "single static BusyBox binary" goal.
  config_set "$config_path" CONFIG_PAM n
  config_set "$config_path" CONFIG_SELINUX n
  config_set "$config_path" CONFIG_FEATURE_WGET_OPENSSL n

  # Keep all applet symbols from allyesconfig. Only trim feature-level options
  # that are known to be unsuitable for small static initrd/live images.
  config_set "$config_path" CONFIG_LOCALE_SUPPORT n
  config_set "$config_path" CONFIG_UNICODE_SUPPORT n
  config_set "$config_path" CONFIG_FEDORA_COMPAT n
  config_set "$config_path" CONFIG_FEATURE_2_4_MODULES n
  config_set "$config_path" CONFIG_FEATURE_VI_REGEX_SEARCH n
  config_set "$config_path" CONFIG_FEATURE_MOUNT_NFS n
  config_set "$config_path" CONFIG_FEATURE_INETD_RPC n
  config_set "$config_path" CONFIG_EXTRA_COMPAT n
  config_set "$config_path" CONFIG_INCLUDE_SUSv2 n
  config_set "$config_path" CONFIG_IOCTL_HEX2STR_ERROR n

  pushd "$src_dir" >/dev/null
  # `yes` exits with SIGPIPE once oldconfig consumes enough input; temporarily
  # disable pipefail so a successful oldconfig run doesn't abort the script.
  set +o pipefail
  yes "" | make oldconfig >/dev/null
  set -o pipefail
  popd >/dev/null
}

patch_busybox_source() {
  local src_dir=$1
  local tc_c="$src_dir/networking/tc.c"
  local tmp="$tc_c.tmp"

  if grep -q "BUSYBOX_TC_CBQ_COMPAT" "$tc_c"; then
    return 0
  fi

  # BusyBox 1.38.0 tc still prints CBQ attributes, but newer linux UAPI
  # headers no longer ship the deprecated CBQ definitions. Add the historical
  # userspace structs back when the toolchain headers do not provide them.
  awk '
    { print }
    /#include <linux\/pkt_sched.h>/ && !inserted {
      print ""
      print "#ifndef TCA_CBQ_MAX"
      print "#define BUSYBOX_TC_CBQ_COMPAT 1"
      print "#define TC_CBQ_MAXPRIO 8"
      print "#define TC_CBQ_MAXLEVEL 8"
      print "#define TC_CBQ_DEF_EWMA 5"
      print "struct tc_cbq_lssopt {"
      print "\tunsigned char change;"
      print "\tunsigned char flags;"
      print "#define TCF_CBQ_LSS_BOUNDED 1"
      print "#define TCF_CBQ_LSS_ISOLATED 2"
      print "\tunsigned char ewma_log;"
      print "\tunsigned char level;"
      print "#define TCF_CBQ_LSS_FLAGS 1"
      print "#define TCF_CBQ_LSS_EWMA 2"
      print "#define TCF_CBQ_LSS_MAXIDLE 4"
      print "#define TCF_CBQ_LSS_MINIDLE 8"
      print "#define TCF_CBQ_LSS_OFFTIME 0x10"
      print "#define TCF_CBQ_LSS_AVPKT 0x20"
      print "\t__u32 maxidle;"
      print "\t__u32 minidle;"
      print "\t__u32 offtime;"
      print "\t__u32 avpkt;"
      print "};"
      print "struct tc_cbq_wrropt {"
      print "\tunsigned char flags;"
      print "\tunsigned char priority;"
      print "\tunsigned char cpriority;"
      print "\tunsigned char __reserved;"
      print "\t__u32 allot;"
      print "\t__u32 weight;"
      print "};"
      print "struct tc_cbq_ovl {"
      print "\tunsigned char strategy;"
      print "#define TC_CBQ_OVL_CLASSIC 0"
      print "#define TC_CBQ_OVL_DELAY 1"
      print "#define TC_CBQ_OVL_LOWPRIO 2"
      print "#define TC_CBQ_OVL_DROP 3"
      print "#define TC_CBQ_OVL_RCLASSIC 4"
      print "\tunsigned char priority2;"
      print "\t__u16 pad;"
      print "\t__u32 penalty;"
      print "};"
      print "struct tc_cbq_police {"
      print "\tunsigned char police;"
      print "\tunsigned char __res1;"
      print "\tunsigned short __res2;"
      print "};"
      print "struct tc_cbq_fopt {"
      print "\t__u32 split;"
      print "\t__u32 defmap;"
      print "\t__u32 defchange;"
      print "};"
      print "struct tc_cbq_xstats {"
      print "\t__u32 borrows;"
      print "\t__u32 overactions;"
      print "\t__s32 avgidle;"
      print "\t__s32 undertime;"
      print "};"
      print "enum {"
      print "\tTCA_CBQ_UNSPEC,"
      print "\tTCA_CBQ_LSSOPT,"
      print "\tTCA_CBQ_WRROPT,"
      print "\tTCA_CBQ_FOPT,"
      print "\tTCA_CBQ_OVL_STRATEGY,"
      print "\tTCA_CBQ_RATE,"
      print "\tTCA_CBQ_RTAB,"
      print "\tTCA_CBQ_POLICE,"
      print "\t__TCA_CBQ_MAX,"
      print "};"
      print "#define TCA_CBQ_MAX (__TCA_CBQ_MAX - 1)"
      print "#endif"
      inserted = 1
    }
  ' "$tc_c" >"$tmp"
  mv "$tmp" "$tc_c"
}

build_target() {
  local target=$1
  local output_name=$2
  local cc=$3
  local strip_tool=$4
  local src_dir="$BUILD_DIR/busybox-src-$target"
  local cflags="$SIZE_CFLAGS"
  local ldflags

  require_tool "$cc"
  require_tool "$strip_tool"

  if [[ "$target" == "aarch64" && "$cc" == "aarch64-linux-musl-gcc" ]]; then
    cflags="$cflags -isystem $(prepare_aarch64_musl_uapi_overlay)"
  fi

  ldflags=$(resolve_static_ldflags "$target" "$cc")

  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar -xf "$SRC_CACHE_DIR/$BUSYBOX_TARBALL" -C "$src_dir" --strip-components=1
  patch_busybox_source "$src_dir"

  prepare_config "$src_dir"

  echo
  echo "Building $output_name with $cc"
  pushd "$src_dir" >/dev/null
  make -j"$JOBS" \
    CC="$cc" \
    STRIP="$strip_tool" \
    HOSTCC=gcc \
    HOSTCXX=g++ \
    EXTRA_CFLAGS="$cflags" \
    EXTRA_LDFLAGS="$ldflags" \
    busybox
  "$strip_tool" -s busybox
  popd >/dev/null

  install -Dm755 "$src_dir/busybox" "$ARTIFACT_DIR/$output_name"
  install -Dm755 "$src_dir/busybox" "$ROOT_DIR/$output_name"

  echo
  echo "Built static $output_name:"
  file "$ARTIFACT_DIR/$output_name"
  ls -lh "$ARTIFACT_DIR/$output_name"
  echo "ELF interpreter entries:"
  readelf -l "$ARTIFACT_DIR/$output_name" | grep -F INTERP || echo "  none"
  echo "Applet count:"
  local runner=()
  if [[ "$target" == "aarch64" ]]; then
    if have_tool qemu-aarch64; then
      runner=(qemu-aarch64 "$ARTIFACT_DIR/$output_name")
    elif have_tool qemu-aarch64-static; then
      runner=(qemu-aarch64-static "$ARTIFACT_DIR/$output_name")
    fi
  else
    runner=("$ARTIFACT_DIR/$output_name")
  fi

  if [[ ${#runner[@]} -gt 0 ]] && "${runner[@]}" --list >"$BUILD_DIR/${output_name}.applets" 2>/dev/null; then
    wc -l <"$BUILD_DIR/${output_name}.applets"
  else
    echo "  cannot execute on this host"
  fi
}

require_tool curl
require_tool tar
require_tool make
require_tool awk gawk
require_tool readelf binutils
require_tool bzip2
require_tool mktemp coreutils
require_tool gcc
require_tool g++ gcc
require_tool "$NATIVE_CC" musl
require_tool "$NATIVE_STRIP" binutils

AARCH64_CC="$(select_aarch64_cc)"
AARCH64_STRIP="$(select_strip "$AARCH64_CC")"

if [[ "$AARCH64_STRIP" == aarch64-linux-gnu-strip ]]; then
  require_tool "$AARCH64_STRIP" aarch64-linux-gnu-binutils
else
  require_tool "$AARCH64_STRIP" binutils
fi

mkdir -p "$SRC_CACHE_DIR" "$ARTIFACT_DIR"
fetch "$BUSYBOX_URL" "$SRC_CACHE_DIR/$BUSYBOX_TARBALL"

build_target native busybox "$NATIVE_CC" "$NATIVE_STRIP"
build_target aarch64 busybox_aarch64 "$AARCH64_CC" "$AARCH64_STRIP"
