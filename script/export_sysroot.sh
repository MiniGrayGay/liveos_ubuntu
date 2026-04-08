#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT_DIR="$ROOT_DIR/sysroot"
OUTPUT_DIR="$ROOT_DIR/output"
TMP_DIR=

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '%s\n' "$*"
}

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR"
  fi
}

require_command() {
  local command_name=$1

  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
}

get_mount_targets() {
  findmnt -rn -o TARGET 2>/dev/null \
    | awk -v sysroot="$SYSROOT_DIR" '
        $0 == sysroot || index($0, sysroot "/") == 1 {
          print
        }
      '
}

sort_mount_targets_by_depth_desc() {
  awk '
    {
      depth = gsub(/\//, "/")
      print depth "\t" $0
    }
  ' | sort -r -n -k1,1 | cut -f2-
}

unmount_sysroot_mounts() {
  local -a mount_targets=()
  local target

  mapfile -t mount_targets < <(get_mount_targets)

  if [ "${#mount_targets[@]}" -eq 0 ]; then
    log "No active mounts found under $SYSROOT_DIR"
    return
  fi

  log "Unmounting active mounts under $SYSROOT_DIR"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    log "Unmounting $target"
    umount "$target"
  done < <(printf '%s\n' "${mount_targets[@]}" | sort_mount_targets_by_depth_desc)

  mapfile -t mount_targets < <(get_mount_targets)
  if [ "${#mount_targets[@]}" -ne 0 ]; then
    printf 'error: failed to unmount all mounts under %s\n' "$SYSROOT_DIR" >&2
    printf 'remaining mounts:\n' >&2
    printf '  %s\n' "${mount_targets[@]}" >&2
    exit 1
  fi

  log "All mounts under $SYSROOT_DIR have been unmounted"
}

next_output_path() {
  local timestamp output_path

  while :; do
    timestamp="$(date +%Y%m%d-%H%M%S)"
    output_path="$OUTPUT_DIR/initrd-$timestamp.zst"
    if [ ! -e "$output_path" ]; then
      printf '%s\n' "$output_path"
      return
    fi
    sleep 1
  done
}

trap cleanup EXIT

[ "${EUID:-$(id -u)}" -eq 0 ] || die "this script must be run as root"
[ -d "$SYSROOT_DIR" ] || die "sysroot directory not found: $SYSROOT_DIR"
mkdir -p "$OUTPUT_DIR"

require_command findmnt
require_command umount
require_command cpio
require_command zstd
require_command sort
require_command mktemp
require_command stat

OUTPUT_PATH="$(next_output_path)"
TMP_DIR="$(mktemp -d "$OUTPUT_DIR/.initrd-export.XXXXXX")"
TMP_OUTPUT_PATH="$TMP_DIR/$(basename "$OUTPUT_PATH")"

log "Preparing to export $SYSROOT_DIR"
unmount_sysroot_mounts

log "Creating archive $OUTPUT_PATH"
(
  cd "$SYSROOT_DIR"
  find . -print0 \
    | LC_ALL=C sort -z \
    | cpio --null -o -H newc --quiet --reproducible \
    | zstd -T0 -19 -o "$TMP_OUTPUT_PATH"
)

mv "$TMP_OUTPUT_PATH" "$OUTPUT_PATH"
log "Created $OUTPUT_PATH ($(stat -c '%s bytes' "$OUTPUT_PATH"))"
