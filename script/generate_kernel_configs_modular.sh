#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_CONFIG="${1:-$ROOT_DIR/kernel/example.config}"
SOURCE_ROOT="${2:-$ROOT_DIR/kernel}"
OUTPUT_DIR="${3:-$ROOT_DIR/kernel}"
SUMMARY_FILE="$OUTPUT_DIR/generated-config-summary-modular.md"
SOURCE_CACHE_DIR="$ROOT_DIR/tmp/kernel-source-cache"
TMP_WORK_ROOT=""

# shellcheck source=/root/kernel/script/kernel_source_matrix.sh
source "$ROOT_DIR/script/kernel_source_matrix.sh"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

force_all_modules_builtin() {
  local cfg=$1
  local tmp

  tmp="$(mktemp)"
  sed -E 's/=(m)$/=y/' "$cfg" >"$tmp"
  mv "$tmp" "$cfg"
}

prepend_header() {
  local target=$1
  local version=$2
  local real_version=$3
  local seed_config=$4
  local tmp
  tmp="$(mktemp)"
  {
    printf '# Generated from %s\n' "$BASE_CONFIG"
    printf '# Seed config: %s\n' "$seed_config"
    printf '# Output profile: modular\n'
    printf '# Output series: Linux/x86_64 %s\n' "$version"
    printf '# Local source tree: %s\n' "${VERSION_TO_SOURCE[$version]}"
    printf '# Actual source version: %s\n' "$real_version"
    cat "$target"
  } >"$tmp"
  mv "$tmp" "$target"
}

ensure_tmp_work_root() {
  if [[ -z "$TMP_WORK_ROOT" ]]; then
    TMP_WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kernel-configs-modular.XXXXXX")
  fi
}

cleanup() {
  if [[ -n "$TMP_WORK_ROOT" && -d "$TMP_WORK_ROOT" ]]; then
    rm -rf "$TMP_WORK_ROOT"
  fi
}

resolve_source_tree() {
  local input_path=$1
  local extract_dir
  local child_dirs=()
  local candidate

  if [[ -d "$input_path" ]]; then
    printf '%s\n' "$input_path"
    return 0
  fi

  if [[ ! -f "$input_path" ]]; then
    return 1
  fi

  case "$input_path" in
    *.tar|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.zst|*.tar.bz2|*.tbz2)
      ensure_tmp_work_root
      extract_dir=$(mktemp -d "$TMP_WORK_ROOT/src.XXXXXX")
      tar -xf "$input_path" -C "$extract_dir"

      if [[ -f "$extract_dir/Makefile" ]]; then
        printf '%s\n' "$extract_dir"
        return 0
      fi

      while IFS= read -r candidate; do
        child_dirs+=("$candidate")
      done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | sort)

      if [[ "${#child_dirs[@]}" -eq 1 && -f "${child_dirs[0]}/Makefile" ]]; then
        printf '%s\n' "${child_dirs[0]}"
        return 0
      fi

      while IFS= read -r candidate; do
        printf '%s\n' "$candidate"
        return 0
      done < <(find "$extract_dir" -mindepth 1 -maxdepth 2 -type f -name Makefile -printf '%h\n' | sort -u)

      return 1
      ;;
  esac

  return 1
}

find_local_source_tree_by_name() {
  local source_name=$1
  local candidate

  for candidate in \
    "$SOURCE_ROOT/$source_name" \
    "$ROOT_DIR/tmp/kernel-source-trees/$source_name"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

fetch_source_archive() {
  local version=$1
  local archive_name archive_path archive_url

  archive_name=$(kernel_tarball_name_for_version "$version")
  archive_path="$SOURCE_CACHE_DIR/$archive_name"
  archive_url=$(kernel_tarball_url_for_version "$version")

  mkdir -p "$SOURCE_CACHE_DIR"

  if [[ ! -f "$archive_path" ]]; then
    printf 'Fetching %s\n' "$archive_url" >&2
    curl -fL --retry 3 --retry-delay 2 -o "$archive_path" "$archive_url"
  fi

  printf '%s\n' "$archive_path"
}

ensure_source_tree_for_series() {
  local version=$1
  local source_name real_version archive_path

  source_name=$(kernel_source_name_for_series "$version") || die "unknown kernel series: $version"
  real_version=$(kernel_full_version_for_series "$version") || die "missing canonical version for $version"

  if find_local_source_tree_by_name "$source_name" >/dev/null; then
    find_local_source_tree_by_name "$source_name"
    return 0
  fi

  archive_path=$(fetch_source_archive "$real_version")
  resolve_source_tree "$archive_path"
}

require_tool curl
require_tool find
require_tool gcc
require_tool make
require_tool mktemp
require_tool sort
require_tool tar

[ -f "$BASE_CONFIG" ] || die "base config not found: $BASE_CONFIG"
[ -d "$SOURCE_ROOT" ] || die "source root not found: $SOURCE_ROOT"
[ -d "$OUTPUT_DIR" ] || die "output dir not found: $OUTPUT_DIR"

declare -A VERSION_TO_SOURCE=()
declare -A VERSION_TO_REAL=()

trap cleanup EXIT
ensure_tmp_work_root

for version in "${KERNEL_SERIES[@]}"; do
  src="$(ensure_source_tree_for_series "$version")" || die "missing source tree for $version"
  VERSION_TO_SOURCE["$version"]="$src"
  VERSION_TO_REAL["$version"]="$(kernel_full_version_for_series "$version")"
  out="$(mktemp -d "$TMP_WORK_ROOT/out-${version}.XXXXXX")"
  cfg="$out/.config"
  target="$OUTPUT_DIR/linux-$version-modular.config"
  seed_config="$OUTPUT_DIR/linux-$version.config"

  [ -x "$src/scripts/config" ] || die "missing scripts/config in $src"

  [[ -f "$seed_config" ]] || die "standard config not found for $version: $seed_config; run generate_kernel_configs.sh first"
  cp "$seed_config" "$cfg"

  sed -i \
    -e '/^CONFIG_BASE_SMALL=/d' \
    -e '/^CONFIG_KASAN_STACK=/d' \
    "$cfg"

  kc() {
    "$src/scripts/config" --file "$cfg" "$@"
  }

  # Keep the standard single-bzImage boot path intact while enabling only the
  # kernel module subsystem used by lsmod, modprobe, insmod, and rmmod.
  kc --enable MODULES
  kc --enable MODULE_UNLOAD
  kc --disable MODULE_UNLOAD_TAINT_TRACKING
  kc --disable MODVERSIONS
  kc --enable KMOD

  make -s -C "$src" O="$out" ARCH=x86 olddefconfig
  for _ in 1 2 3; do
    if ! grep -q '=m$' "$cfg"; then
      break
    fi
    force_all_modules_builtin "$cfg"
    make -s -C "$src" O="$out" ARCH=x86 olddefconfig
  done
  if grep -q '=m$' "$cfg"; then
    grep '=m$' "$cfg" >&2
    die "generated modular config for $version still contains loadable modules"
  fi
  cp "$cfg" "$target"
  prepend_header "$target" "$version" "${VERSION_TO_REAL[$version]}" "$seed_config"
  chmod 0644 "$target"
done

{
  printf '# Generated modular kernel configs\n\n'
  printf 'Base config: `%s`\n\n' "$BASE_CONFIG"
  printf 'Profile: derive directly from the standard configs and keep a single `bzImage` boot path, while enabling only the module syscalls needed by `lsmod`, `modprobe`, `insmod`, and `rmmod` via `CONFIG_MODULES` and `CONFIG_MODULE_UNLOAD`.\n\n'
  printf 'No selected driver or filesystem is emitted as `=m`; generated configs are checked to ensure they do not require an external module tree.\n\n'
  printf '| Series | Real source | Output file |\n'
  printf '| --- | --- | --- |\n'
  for version in "${KERNEL_SERIES[@]}"; do
    printf '| `%s` | `%s` | `%s/linux-%s-modular.config` |\n' \
      "$version" "${VERSION_TO_REAL[$version]}" "$OUTPUT_DIR" "$version"
  done
} >"$SUMMARY_FILE"

printf 'Generated modular configs in %s\n' "$OUTPUT_DIR"
printf 'Summary written to %s\n' "$SUMMARY_FILE"
