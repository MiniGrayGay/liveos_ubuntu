#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KERNEL_DIR="$ROOT_DIR/kernel"
OUTPUT_DIR="$ROOT_DIR/output"
JOBS=${JOBS:-$(nproc)}
TMP_WORK_ROOT=""

declare -a SOURCES=(
  "5.10|linux-5.10.252"
  "5.15|linux-5.15.202"
  "6.1|linux-6.1.167"
  "6.6|linux-6.6.133"
  "6.12|linux-6.12.80"
  "6.18|linux-6.18.21"
)

usage() {
  cat <<'EOF'
Usage: compile_kernel_outputs.sh [--mod|--std|--both] [version|version-mod|/path/to/linux-source ...]

Without arguments:
  Build all configured versions in both standard and modular flavors.

With arguments:
  --mod           Build only the modular flavor for following inputs
  --std           Build only the standard flavor for following inputs
  --both          Build both flavors for following inputs (default)
  5.10           Build standard and modular outputs for 5.10
  6.18           Build standard and modular outputs for 6.18
  6.18-mod       Build only the modular output for 6.18
  6.18-modular   Build only the modular output for 6.18
  /path/linux-6.18.21
                 Detect source version from the path name, prefer the same
                 config series, otherwise use the nearest lower config series
                 and run olddefconfig
  /tmp/linux-6.19.11.tar.xz
                 Extract the archive, detect 6.19.11 from the file name, then
                 fall back to the nearest lower config series such as 6.18

Examples:
  ./script/compile_kernel_outputs.sh 6.18
  ./script/compile_kernel_outputs.sh 6.18-mod
  ./script/compile_kernel_outputs.sh --mod /tmp/linux-6.19.11.tar.xz
  ./script/compile_kernel_outputs.sh 5.10 6.18
  ./script/compile_kernel_outputs.sh /work/linux-6.18.21
  ./script/compile_kernel_outputs.sh /tmp/linux-6.19.11.tar.xz
EOF
}

find_source_name() {
  local wanted=$1
  local short_ver
  local source_name

  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r short_ver source_name <<<"$entry"
    if [[ "$short_ver" == "$wanted" ]]; then
      printf '%s\n' "$source_name"
      return 0
    fi
  done

  return 1
}

version_sort_key() {
  local version=$1
  local major minor patch

  IFS='.' read -r major minor patch <<<"$version"
  patch=${patch:-0}
  printf '%05d%05d%05d\n' "$major" "$minor" "$patch"
}

detect_version_from_name() {
  local name=$1
  local base=${name##*/}

  base=${base%.tar.gz}
  base=${base%.tar.xz}
  base=${base%.tar.zst}
  base=${base%.tar.bz2}
  base=${base%.tgz}
  base=${base%.txz}
  base=${base%.tbz2}

  if [[ "$base" =~ ([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
    printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-0}"
    return 0
  fi

  return 1
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

find_best_config_series() {
  local detected_version=$1
  local short_series=${detected_version%.*}
  local detected_key best_series="" best_key=""
  local entry source_name candidate_key
  local candidate_series

  detected_key=$(version_sort_key "$detected_version")

  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r candidate_series source_name <<<"$entry"
    if [[ "$candidate_series" == "$short_series" ]]; then
      printf '%s\n' "$candidate_series"
      return 0
    fi
  done

  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r candidate_series source_name <<<"$entry"
    candidate_key=$(version_sort_key "$candidate_series")
    if [[ "$candidate_key" > "$detected_key" ]]; then
      continue
    fi
    if [[ -z "$best_key" || "$candidate_key" > "$best_key" ]]; then
      best_key=$candidate_key
      best_series=$candidate_series
    fi
  done

  [[ -n "$best_series" ]] || return 1
  printf '%s\n' "$best_series"
}

build_one() {
  local display_ver=$1
  local config_ver=$2
  local source_dir=$3
  local flavor=$4

  local config_suffix=""
  local output_name="$display_ver"
  if [[ "$flavor" == "modular" ]]; then
    config_suffix="-modular"
    output_name="${display_ver}-mod"
  fi

  local config_path="$KERNEL_DIR/linux-${config_ver}${config_suffix}.config"
  local target_dir="$OUTPUT_DIR/$output_name"
  local build_dir="$target_dir/build"
  local image_path="$build_dir/arch/x86/boot/bzImage"

  [[ -d "$source_dir" ]] || {
    printf 'error: source tree not found: %s\n' "$source_dir" >&2
    exit 1
  }
  [[ -f "$config_path" ]] || {
    printf 'error: config not found: %s\n' "$config_path" >&2
    exit 1
  }

  echo "==> Building $output_name from $(basename "$source_dir") using linux-${config_ver}${config_suffix}.config"
  rm -rf "$target_dir"
  mkdir -p "$build_dir"

  cp "$config_path" "$build_dir/.config"

  make -C "$source_dir" O="$build_dir" olddefconfig
  if grep -q '^CONFIG_MODULES=y' "$build_dir/.config"; then
    make -C "$source_dir" O="$build_dir" -j"$JOBS" bzImage modules
  else
    make -C "$source_dir" O="$build_dir" -j"$JOBS" bzImage
  fi

  local kernelrelease
  kernelrelease=$(make -s -C "$source_dir" O="$build_dir" kernelrelease)

  cp "$image_path" "$target_dir/bzImage"
  cp "$build_dir/vmlinux" "$target_dir/vmlinux"
  cp "$build_dir/System.map" "$target_dir/System.map"
  cp "$build_dir/.config" "$target_dir/config"

  cat >"$target_dir/build-info.txt" <<EOF
display_version=$output_name
source_tree=$source_dir
source_series=$display_ver
config_series=$config_ver
config=$config_path
kernelrelease=$kernelrelease
jobs=$JOBS
EOF
}

main() {
  trap cleanup EXIT
  mkdir -p "$OUTPUT_DIR"

  local short_ver
  local source_name
  local request
  local flavor
  local base_ver
  local source_dir
  local detected_version
  local config_ver
  local mode=both

  if [[ "$#" -eq 0 ]]; then
    for entry in "${SOURCES[@]}"; do
      IFS='|' read -r short_ver source_name <<<"$entry"
      build_one "$short_ver" "$short_ver" "$KERNEL_DIR/$source_name" standard
      build_one "$short_ver" "$short_ver" "$KERNEL_DIR/$source_name" modular
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
    esac

    if [[ -e "$request" ]]; then
      detected_version=$(detect_version_from_name "$request") || {
        printf 'error: could not detect kernel version from path name: %s\n' "$request" >&2
        exit 1
      }
      source_dir=$(resolve_source_tree "$request") || {
        printf 'error: could not resolve a kernel source tree from: %s\n' "$request" >&2
        exit 1
      }
      config_ver=$(find_best_config_series "$detected_version") || {
        printf 'error: no usable config series found for source version %s\n' "$detected_version" >&2
        exit 1
      }
      case "$mode" in
        standard)
          build_one "$detected_version" "$config_ver" "$source_dir" standard
          ;;
        modular)
          build_one "$detected_version" "$config_ver" "$source_dir" modular
          ;;
        both)
          build_one "$detected_version" "$config_ver" "$source_dir" standard
          build_one "$detected_version" "$config_ver" "$source_dir" modular
          ;;
      esac
      continue
    fi

    case "$request" in
      -h|--help)
        usage
        return
        ;;
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

    source_name=$(find_source_name "$base_ver") || {
      printf 'error: unknown kernel version: %s\n' "$request" >&2
      usage >&2
      exit 1
    }

    if [[ "$flavor" == "modular" ]]; then
      build_one "$base_ver" "$base_ver" "$KERNEL_DIR/$source_name" modular
    elif [[ "$mode" == "standard" ]]; then
      build_one "$base_ver" "$base_ver" "$KERNEL_DIR/$source_name" standard
    elif [[ "$mode" == "modular" ]]; then
      build_one "$base_ver" "$base_ver" "$KERNEL_DIR/$source_name" modular
    else
      build_one "$base_ver" "$base_ver" "$KERNEL_DIR/$source_name" standard
      build_one "$base_ver" "$base_ver" "$KERNEL_DIR/$source_name" modular
    fi
  done
}

main "$@"
