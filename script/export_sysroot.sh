#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT_DIR="$ROOT_DIR/sysroot"
OUTPUT_DIR="$ROOT_DIR/output"
TMP_DIR=
SPLIT=0
LIB_DIR=

usage() {
  cat <<'EOF'
Usage: export_sysroot.sh [--split]

Package the sysroot directory into a zstd-compressed newc cpio initrd.

Options:
  --split   Emit two initrds instead of one:
              initrd-<timestamp>.1.zst  everything except the libraries (/lib)
              initrd-<timestamp>.2.zst  the libraries only (/lib -> usr/lib)
            The kernel concatenates multiple initrds, so this works around
            per-file size limits. Pass the .1 image before the .2 image at boot.
  -h, --help  Show this help and exit.
EOF
}

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

next_output_base() {
  local timestamp base

  while :; do
    timestamp="$(date +%Y%m%d-%H%M%S)"
    base="$OUTPUT_DIR/initrd-$timestamp"
    if [ "$SPLIT" -eq 1 ]; then
      if [ ! -e "$base.1.zst" ] && [ ! -e "$base.2.zst" ]; then
        printf '%s\n' "$base"
        return
      fi
    elif [ ! -e "$base.zst" ]; then
      printf '%s\n' "$base"
      return
    fi
    sleep 1
  done
}

# Resolve the path (relative to the sysroot, as `find` prints it) that holds the
# shared libraries. On merged-/usr systems /lib is a symlink to usr/lib, so the
# real content lives there.
resolve_lib_dir() {
  local target

  if [ -L "$SYSROOT_DIR/lib" ]; then
    target="$(readlink "$SYSROOT_DIR/lib")"
    target="${target#/}"
    printf './%s\n' "$target"
  elif [ -d "$SYSROOT_DIR/lib" ]; then
    printf './lib\n'
  else
    die "no lib directory found in sysroot: $SYSROOT_DIR/lib"
  fi
}

# create_initrd <destination.zst> <all|no-lib|lib>
create_initrd() {
  local dest=$1 mode=$2
  local tmp
  tmp="$TMP_DIR/$(basename "$dest")"

  log "Creating archive $dest"
  (
    cd "$SYSROOT_DIR"
    case "$mode" in
      all)
        find . -print0
        ;;
      no-lib)
        find . -path "$LIB_DIR" -prune -o -print0
        ;;
      lib)
        find "$LIB_DIR" -print0
        ;;
      *)
        die "unknown archive mode: $mode"
        ;;
    esac \
      | LC_ALL=C sort -z \
      | cpio --null -o -H newc --quiet --reproducible \
      | zstd -T0 -19 -o "$tmp"
  )
  mv "$tmp" "$dest"
  log "Created $dest ($(stat -c '%s bytes' "$dest"))"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --split)
      SPLIT=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

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
if [ "$SPLIT" -eq 1 ]; then
  require_command readlink
fi

OUTPUT_BASE="$(next_output_base)"
TMP_DIR="$(mktemp -d "$OUTPUT_DIR/.initrd-export.XXXXXX")"

log "Preparing to export $SYSROOT_DIR"
unmount_sysroot_mounts

if [ "$SPLIT" -eq 1 ]; then
  LIB_DIR="$(resolve_lib_dir)"
  log "Splitting initrd; libraries live in $LIB_DIR"
  create_initrd "$OUTPUT_BASE.1.zst" no-lib
  create_initrd "$OUTPUT_BASE.2.zst" lib
  log "Split complete; at boot load $(basename "$OUTPUT_BASE.1.zst") before $(basename "$OUTPUT_BASE.2.zst")"
else
  create_initrd "$OUTPUT_BASE.zst" all
fi
