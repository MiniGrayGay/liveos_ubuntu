#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KERNEL_DIR="$ROOT_DIR/kernel"
OUTPUT_DIR="$ROOT_DIR/output"
JOBS=${JOBS:-$(nproc)}

declare -a SOURCES=(
  "5.10|linux-5.10.252"
  "5.15|linux-5.15.202"
  "6.1|linux-6.1.167"
  "6.6|linux-6.6.133"
  "6.12|linux-6.12.80"
  "6.18|linux-6.18.21"
)

build_one() {
  local short_ver=$1
  local source_name=$2
  local flavor=$3

  local config_suffix=""
  local output_name="$short_ver"
  if [[ "$flavor" == "modular" ]]; then
    config_suffix="-modular"
    output_name="${short_ver}-mod"
  fi

  local source_dir="$KERNEL_DIR/$source_name"
  local config_path="$KERNEL_DIR/linux-${short_ver}${config_suffix}.config"
  local target_dir="$OUTPUT_DIR/$output_name"
  local build_dir="$target_dir/build"
  local image_path="$build_dir/arch/x86/boot/bzImage"

  echo "==> Building $output_name from $source_name"
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
source_series=$short_ver
config=$config_path
kernelrelease=$kernelrelease
jobs=$JOBS
EOF
}

main() {
  mkdir -p "$OUTPUT_DIR"

  local short_ver
  local source_name
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r short_ver source_name <<<"$entry"
    build_one "$short_ver" "$source_name" standard
    build_one "$short_ver" "$source_name" modular
  done
}

main "$@"
