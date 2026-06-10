#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KERNEL_DIR="$ROOT_DIR/kernel"
OUTPUT_DIR="$ROOT_DIR/output"
SOURCE_CACHE_DIR="$ROOT_DIR/tmp/kernel-source-cache"
JOBS=${JOBS:-$(nproc)}
TMP_WORK_ROOT=""

# shellcheck source=/root/kernel/script/kernel_source_matrix.sh
source "$ROOT_DIR/script/kernel_source_matrix.sh"

usage() {
  cat <<'EOF'
Usage: compile_kernel_outputs.sh [--aarch64|--x86_64] [--mod|--std|--both] [version|version-mod|x.y.z|/path/to/linux-source ...]

Without arguments:
  Build all configured series in both standard and modular flavors using the
  latest active patch versions from kernel.org, downloading them when needed.

With arguments:
  --mod           Build only the modular flavor for following inputs
  --std           Build only the standard flavor for following inputs
  --both          Build both flavors for following inputs (default)
  --aarch64       Build arm64/aarch64 kernel images. Outputs are written to
                  output/<version>-aarch64 and output/<version>-aarch64-mod.
  --x86_64        Build x86_64 kernel images (default)
  5.10            Build standard and modular outputs for the latest active
                  5.10.y release from kernel.org
  6.18-mod        Build only the modular output for series 6.18 using
                  the latest active 6.18.y release from kernel.org
  6.18.22         Build standard and modular outputs for linux-6.18.22
  /path/linux-6.18.22
                  Use the provided source tree and the nearest matching config
                  series, running olddefconfig before the build
  /tmp/linux-6.19.11.tar.xz
                  Extract the archive, detect 6.19.11 from the file name, then
                  fall back to the nearest lower config series such as 6.18

Examples:
  ./script/compile_kernel_outputs.sh 6.18
  ./script/compile_kernel_outputs.sh 6.18-mod
  ./script/compile_kernel_outputs.sh 6.18.22
  ./script/compile_kernel_outputs.sh --mod 6.18.22
  ./script/compile_kernel_outputs.sh --aarch64 6.18
  ./script/compile_kernel_outputs.sh /tmp/linux-6.19.11.tar.xz
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing required tool: %s\n' "$1" >&2
    exit 1
  }
}

ensure_tmp_work_root() {
  if [[ -z "$TMP_WORK_ROOT" ]]; then
    TMP_WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/compile-kernel.XXXXXX")
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
    "$KERNEL_DIR/$source_name" \
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
    printf '==> Downloading %s\n' "$archive_url" >&2
    curl -fL --retry 3 --retry-delay 2 -o "$archive_path" "$archive_url"
  fi

  printf '%s\n' "$archive_path"
}

ensure_source_tree_for_series() {
  local series=$1
  local source_name full_version archive_path

  source_name=$(kernel_source_name_for_series "$series") || {
    printf 'error: unknown kernel series: %s\n' "$series" >&2
    exit 1
  }

  if find_local_source_tree_by_name "$source_name" >/dev/null; then
    find_local_source_tree_by_name "$source_name"
    return 0
  fi

  full_version=$(kernel_full_version_for_series "$series") || {
    printf 'error: missing canonical version for series: %s\n' "$series" >&2
    exit 1
  }
  archive_path=$(fetch_source_archive "$full_version")
  resolve_source_tree "$archive_path"
}

ensure_source_tree_for_exact_version() {
  local version=$1
  local source_name archive_path

  source_name="linux-$version"

  if find_local_source_tree_by_name "$source_name" >/dev/null; then
    find_local_source_tree_by_name "$source_name"
    return 0
  fi

  archive_path=$(fetch_source_archive "$version")
  resolve_source_tree "$archive_path"
}

kernel_make_vars_for_arch() {
  local target_arch=$1

  case "$target_arch" in
    x86_64)
      printf '%s\n' "ARCH=x86"
      ;;
    aarch64)
      printf '%s\n' "ARCH=arm64" "CROSS_COMPILE=${AARCH64_CROSS_COMPILE:-aarch64-linux-gnu-}"
      ;;
    *)
      printf 'error: unsupported target architecture: %s\n' "$target_arch" >&2
      exit 1
      ;;
  esac
}

kernel_image_target_for_arch() {
  local target_arch=$1

  case "$target_arch" in
    x86_64) printf '%s\n' "bzImage" ;;
    aarch64) printf '%s\n' "Image.gz" ;;
    *)
      printf 'error: unsupported target architecture: %s\n' "$target_arch" >&2
      exit 1
      ;;
  esac
}

kernel_image_path_for_arch() {
  local target_arch=$1
  local build_dir=$2

  case "$target_arch" in
    x86_64) printf '%s\n' "$build_dir/arch/x86/boot/bzImage" ;;
    aarch64) printf '%s\n' "$build_dir/arch/arm64/boot/Image.gz" ;;
    *)
      printf 'error: unsupported target architecture: %s\n' "$target_arch" >&2
      exit 1
      ;;
  esac
}

kernel_output_image_name_for_arch() {
  local target_arch=$1

  case "$target_arch" in
    x86_64) printf '%s\n' "bzImage" ;;
    aarch64) printf '%s\n' "Image.gz" ;;
    *)
      printf 'error: unsupported target architecture: %s\n' "$target_arch" >&2
      exit 1
      ;;
  esac
}

require_arch_tools() {
  local target_arch=$1
  local cross_compile

  if [[ "$target_arch" == "aarch64" ]]; then
    cross_compile=${AARCH64_CROSS_COMPILE:-aarch64-linux-gnu-}
    require_tool "${cross_compile}gcc"
  fi
}

build_one() {
  local display_ver=$1
  local config_ver=$2
  local source_dir=$3
  local flavor=$4
  local target_arch=${5:-x86_64}
  local source_series=$display_ver

  local config_suffix=""
  local output_name="$display_ver"
  local arch_suffix=""
  local modules_enabled=0
  local loadable_modules_enabled=0

  if [[ "$target_arch" == "aarch64" ]]; then
    arch_suffix="-aarch64"
  fi

  if [[ "$flavor" == "modular" ]]; then
    config_suffix="-modular"
    output_name="${display_ver}${arch_suffix}-mod"
  else
    output_name="${display_ver}${arch_suffix}"
  fi

  if [[ "$display_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    source_series=${display_ver%.*}
  fi

  local config_path="$KERNEL_DIR/linux-${config_ver}${config_suffix}.config"
  local target_dir="$OUTPUT_DIR/$output_name"
  local build_dir="$target_dir/build"
  local image_target
  local image_path
  local output_image_name
  local -a make_vars=()

  mapfile -t make_vars < <(kernel_make_vars_for_arch "$target_arch")
  image_target=$(kernel_image_target_for_arch "$target_arch")
  image_path=$(kernel_image_path_for_arch "$target_arch" "$build_dir")
  output_image_name=$(kernel_output_image_name_for_arch "$target_arch")

  [[ -d "$source_dir" ]] || {
    printf 'error: source tree not found: %s\n' "$source_dir" >&2
    exit 1
  }
  [[ -f "$config_path" ]] || {
    printf 'error: config not found: %s\n' "$config_path" >&2
    exit 1
  }

  require_arch_tools "$target_arch"

  echo "==> Building $output_name from $(basename "$source_dir") using linux-${config_ver}${config_suffix}.config"
  rm -rf "$target_dir"
  mkdir -p "$build_dir"

  cp "$config_path" "$build_dir/.config"

  make -C "$source_dir" O="$build_dir" "${make_vars[@]}" olddefconfig
  if grep -q '^CONFIG_MODULES=y' "$build_dir/.config"; then
    modules_enabled=1
  fi
  if grep -q '=m$' "$build_dir/.config"; then
    loadable_modules_enabled=1
  fi

  if [[ "$loadable_modules_enabled" -eq 1 ]]; then
    make -C "$source_dir" O="$build_dir" "${make_vars[@]}" -j"$JOBS" "$image_target" modules
  else
    make -C "$source_dir" O="$build_dir" "${make_vars[@]}" -j"$JOBS" "$image_target"
  fi

  local kernelrelease
  kernelrelease=$(make -s -C "$source_dir" O="$build_dir" "${make_vars[@]}" kernelrelease)

  if [[ "$loadable_modules_enabled" -eq 1 ]]; then
    make -C "$source_dir" O="$build_dir" "${make_vars[@]}" INSTALL_MOD_PATH="$target_dir" modules_install
    depmod -b "$target_dir" -F "$build_dir/System.map" "$kernelrelease"
  fi

  cp "$image_path" "$target_dir/$output_image_name"
  cp "$build_dir/vmlinux" "$target_dir/vmlinux"
  cp "$build_dir/System.map" "$target_dir/System.map"
  cp "$build_dir/.config" "$target_dir/config"

  {
    printf 'display_version=%s\n' "$output_name"
    printf 'source_tree=%s\n' "$source_dir"
    printf 'source_version=%s\n' "$(kernel_detect_version_from_name "$source_dir" || true)"
    printf 'source_series=%s\n' "$source_series"
    printf 'config_series=%s\n' "$config_ver"
    printf 'config=%s\n' "$config_path"
    printf 'target_arch=%s\n' "$target_arch"
    printf 'kernel_arch=%s\n' "${make_vars[0]#ARCH=}"
    printf 'image_target=%s\n' "$image_target"
    printf 'image_file=%s\n' "$target_dir/$output_image_name"
    if [[ "$target_arch" == "aarch64" ]]; then
      printf 'cross_compile=%s\n' "${AARCH64_CROSS_COMPILE:-aarch64-linux-gnu-}"
    fi
    printf 'kernelrelease=%s\n' "$kernelrelease"
    printf 'jobs=%s\n' "$JOBS"
    printf 'modules_enabled=%s\n' "$modules_enabled"
    printf 'loadable_modules_enabled=%s\n' "$loadable_modules_enabled"
    if [[ "$loadable_modules_enabled" -eq 1 ]]; then
      printf 'modules_dir=%s\n' "$target_dir/lib/modules/$kernelrelease"
    fi
  } >"$target_dir/build-info.txt"
}

build_from_detected_version() {
  local detected_version=$1
  local source_dir=$2
  local mode=$3
  local target_arch=${4:-x86_64}
  local config_ver

  config_ver=$(kernel_find_best_series_for_version "$detected_version") || {
    printf 'error: no usable config series found for source version %s\n' "$detected_version" >&2
    exit 1
  }

  case "$mode" in
    standard)
      build_one "$detected_version" "$config_ver" "$source_dir" standard "$target_arch"
      ;;
    modular)
      build_one "$detected_version" "$config_ver" "$source_dir" modular "$target_arch"
      ;;
    both)
      build_one "$detected_version" "$config_ver" "$source_dir" standard "$target_arch"
      build_one "$detected_version" "$config_ver" "$source_dir" modular "$target_arch"
      ;;
  esac
}

main() {
  trap cleanup EXIT
  mkdir -p "$OUTPUT_DIR"

  require_tool curl
  require_tool depmod
  require_tool find
  require_tool make
  require_tool sort
  require_tool tar

  local request
  local flavor
  local base_ver
  local source_dir
  local detected_version
  local mode=both
  local short_ver
  local target_arch=x86_64
  local built_any=0

  if [[ "$#" -eq 0 ]]; then
    for short_ver in "${KERNEL_SERIES[@]}"; do
      source_dir=$(ensure_source_tree_for_series "$short_ver")
      build_one "$short_ver" "$short_ver" "$source_dir" standard "$target_arch"
      build_one "$short_ver" "$short_ver" "$source_dir" modular "$target_arch"
    done
    return
  fi

  for request in "$@"; do
    case "$request" in
      --mod|--modular)
        mode=modular
        continue
        ;;
      --std|--standard)
        mode=standard
        continue
        ;;
      --both)
        mode=both
        continue
        ;;
      --aarch64|--arm64)
        target_arch=aarch64
        continue
        ;;
      --x86_64|--amd64|--x86)
        target_arch=x86_64
        continue
        ;;
      -h|--help)
        usage
        return
        ;;
    esac

    if [[ -e "$request" ]]; then
      detected_version=$(kernel_detect_version_from_name "$request") || {
        printf 'error: could not detect kernel version from path name: %s\n' "$request" >&2
        exit 1
      }
      source_dir=$(resolve_source_tree "$request") || {
        printf 'error: could not resolve a kernel source tree from: %s\n' "$request" >&2
        exit 1
      }
      build_from_detected_version "$detected_version" "$source_dir" "$mode" "$target_arch"
      built_any=1
      continue
    fi

    case "$request" in
      *-mod|*-modular)
        flavor=modular
        base_ver=${request%-modular}
        base_ver=${base_ver%-mod}
        ;;
      *)
        flavor=both
        base_ver=$request
        ;;
    esac

    if [[ "$base_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      source_dir=$(ensure_source_tree_for_exact_version "$base_ver")
      if [[ "$flavor" == "modular" ]]; then
        build_from_detected_version "$base_ver" "$source_dir" modular "$target_arch"
      elif [[ "$mode" == "standard" ]]; then
        build_from_detected_version "$base_ver" "$source_dir" standard "$target_arch"
      elif [[ "$mode" == "modular" ]]; then
        build_from_detected_version "$base_ver" "$source_dir" modular "$target_arch"
      else
        build_from_detected_version "$base_ver" "$source_dir" both "$target_arch"
      fi
      built_any=1
      continue
    fi

    kernel_source_name_for_series "$base_ver" >/dev/null || {
      printf 'error: unknown kernel version: %s\n' "$request" >&2
      usage >&2
      exit 1
    }
    source_dir=$(ensure_source_tree_for_series "$base_ver")

    if [[ "$flavor" == "modular" ]]; then
      build_one "$base_ver" "$base_ver" "$source_dir" modular "$target_arch"
    elif [[ "$mode" == "standard" ]]; then
      build_one "$base_ver" "$base_ver" "$source_dir" standard "$target_arch"
    elif [[ "$mode" == "modular" ]]; then
      build_one "$base_ver" "$base_ver" "$source_dir" modular "$target_arch"
    else
      build_one "$base_ver" "$base_ver" "$source_dir" standard "$target_arch"
      build_one "$base_ver" "$base_ver" "$source_dir" modular "$target_arch"
    fi
    built_any=1
  done

  if [[ "$built_any" -eq 0 ]]; then
    for short_ver in "${KERNEL_SERIES[@]}"; do
      source_dir=$(ensure_source_tree_for_series "$short_ver")
      if [[ "$mode" == "standard" ]]; then
        build_one "$short_ver" "$short_ver" "$source_dir" standard "$target_arch"
      elif [[ "$mode" == "modular" ]]; then
        build_one "$short_ver" "$short_ver" "$source_dir" modular "$target_arch"
      else
        build_one "$short_ver" "$short_ver" "$source_dir" standard "$target_arch"
        build_one "$short_ver" "$short_ver" "$source_dir" modular "$target_arch"
      fi
    done
  fi
}

main "$@"
