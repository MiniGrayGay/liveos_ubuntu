#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/output"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEMORY="${QEMU_MEMORY:-2048}"
QEMU_SMP="${QEMU_SMP:-2}"
DEFAULT_QEMU_APPEND_GUI="console=tty0 rdinit=/init loglevel=8 ignore_loglevel printk.time=1"
DEFAULT_QEMU_APPEND_NOGRAPHIC="console=ttyS0,115200 rdinit=/init loglevel=8 ignore_loglevel printk.time=1"
DRY_RUN=0
GUI=0
POSITIONAL_KERNEL_PATH=
POSITIONAL_INITRD_PATH=
USER_KERNEL_PROVIDED=0
USER_INITRD_PROVIDED=0
USER_APPEND_PROVIDED=0
declare -a USER_QEMU_ARGS=()

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: script/run_qemu.sh [kernel_path] [initrd_path] [qemu args...]

Default behavior:
  - load the highest-version non-mod kernel from output/bzImage_*
  - load the newest initramfs from output/initrd-*.zst
  - GUI mode passes -append "console=tty0 rdinit=/init loglevel=8 ignore_loglevel printk.time=1"
  - nographic mode passes -append "console=ttyS0,115200 rdinit=/init loglevel=8 ignore_loglevel printk.time=1"
  - pass -no-reboot, and add -nographic unless --gui is used

Options:
  --qemu-bin PATH   QEMU binary, default: qemu-system-x86_64
  --gui             Do not add -nographic
  --dry-run         Print the resolved command without launching QEMU
  -h, --help        Show this help text

Overrides:
  - if qemu args contain -kernel, -initrd, or -append, the corresponding defaults are skipped
  - unrecognized args are forwarded to qemu as-is

Environment overrides:
  QEMU_BIN
  QEMU_MEMORY
  QEMU_SMP
  QEMU_APPEND
EOF
}

require_command() {
  local command_name=$1

  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
}

find_latest_standard_kernel() {
  local version

  version="$(
    find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'bzImage_*' -printf '%f\n' 2>/dev/null \
      | sed -n '/-mod$/d; s/^bzImage_//p' \
      | sort -V \
      | tail -n 1
  )"

  [ -n "$version" ] || return 1
  printf '%s\n' "$OUTPUT_DIR/bzImage_$version"
}

find_latest_initrd() {
  local path

  path="$(
    find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'initrd-*' -printf '%T@ %p\n' 2>/dev/null \
      | sort -n \
      | tail -n 1 \
      | cut -d' ' -f2-
  )"

  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

# Only treat the first two leading non-option args as positional paths.
while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
  if [ -z "${POSITIONAL_KERNEL_PATH:-}" ]; then
    POSITIONAL_KERNEL_PATH=$1
  elif [ -z "${POSITIONAL_INITRD_PATH:-}" ]; then
    POSITIONAL_INITRD_PATH=$1
  else
    break
  fi
  shift
done

while [ $# -gt 0 ]; do
  case "$1" in
    --qemu-bin)
      [ $# -ge 2 ] || die "--qemu-bin requires a path"
      QEMU_BIN=$2
      shift 2
      ;;
    --gui)
      GUI=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -kernel)
      [ $# -ge 2 ] || die "-kernel requires a value"
      USER_KERNEL_PROVIDED=1
      USER_QEMU_ARGS+=("$1" "$2")
      shift 2
      ;;
    -initrd)
      [ $# -ge 2 ] || die "-initrd requires a value"
      USER_INITRD_PROVIDED=1
      USER_QEMU_ARGS+=("$1" "$2")
      shift 2
      ;;
    -append)
      [ $# -ge 2 ] || die "-append requires a value"
      USER_APPEND_PROVIDED=1
      USER_QEMU_ARGS+=("$1" "$2")
      shift 2
      ;;
    -kernel=*|--kernel=*)
      USER_KERNEL_PROVIDED=1
      USER_QEMU_ARGS+=("$1")
      shift
      ;;
    -initrd=*|--initrd=*)
      USER_INITRD_PROVIDED=1
      USER_QEMU_ARGS+=("$1")
      shift
      ;;
    -append=*|--append=*)
      USER_APPEND_PROVIDED=1
      USER_QEMU_ARGS+=("$1")
      shift
      ;;
    *)
      USER_QEMU_ARGS+=("$1")
      shift
      ;;
  esac
done

[ -d "$OUTPUT_DIR" ] || die "output directory not found: $OUTPUT_DIR"
require_command "$QEMU_BIN"

KERNEL_PATH=
INITRD_PATH=
QEMU_APPEND=

if [ "$USER_KERNEL_PROVIDED" -eq 0 ]; then
  if [ -n "${POSITIONAL_KERNEL_PATH:-}" ]; then
    KERNEL_PATH=$POSITIONAL_KERNEL_PATH
  else
    KERNEL_PATH="$(find_latest_standard_kernel)" || die "no non-mod kernel image found under $OUTPUT_DIR"
  fi
fi

if [ "$USER_INITRD_PROVIDED" -eq 0 ]; then
  if [ -n "${POSITIONAL_INITRD_PATH:-}" ]; then
    INITRD_PATH=$POSITIONAL_INITRD_PATH
  else
    INITRD_PATH="$(find_latest_initrd)" || die "no initramfs image found under $OUTPUT_DIR"
  fi
fi

if [ "$USER_APPEND_PROVIDED" -eq 0 ]; then
  if [ -n "${QEMU_APPEND:-}" ]; then
    QEMU_APPEND=$QEMU_APPEND
  elif [ "$GUI" -eq 1 ]; then
    QEMU_APPEND=$DEFAULT_QEMU_APPEND_GUI
  else
    QEMU_APPEND=$DEFAULT_QEMU_APPEND_NOGRAPHIC
  fi
fi

if [ -n "${KERNEL_PATH:-}" ]; then
  [ -f "$KERNEL_PATH" ] || die "kernel image not found: $KERNEL_PATH"
fi

if [ -n "${INITRD_PATH:-}" ]; then
  [ -f "$INITRD_PATH" ] || die "initramfs image not found: $INITRD_PATH"
fi

declare -a QEMU_ARGS=(
  -machine accel=kvm:tcg
  -m "$QEMU_MEMORY"
  -smp "$QEMU_SMP"
  -nic user,model=virtio-net-pci
  -no-reboot
)

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  QEMU_ARGS+=(-cpu host)
fi

if [ -n "${KERNEL_PATH:-}" ]; then
  QEMU_ARGS+=(-kernel "$KERNEL_PATH")
fi

if [ -n "${INITRD_PATH:-}" ]; then
  QEMU_ARGS+=(-initrd "$INITRD_PATH")
fi

if [ -n "${QEMU_APPEND:-}" ]; then
  QEMU_ARGS+=(-append "$QEMU_APPEND")
fi

if [ "$GUI" -eq 0 ]; then
  QEMU_ARGS+=(-nographic)
fi

if [ "${#USER_QEMU_ARGS[@]}" -gt 0 ]; then
  QEMU_ARGS+=("${USER_QEMU_ARGS[@]}")
fi

printf 'Kernel : %s\n' "${KERNEL_PATH:-<from user qemu args>}"
printf 'Initrd : %s\n' "${INITRD_PATH:-<from user qemu args>}"
printf 'Append : %s\n' "${QEMU_APPEND:-<from user qemu args>}"
printf 'QEMU   : %s\n' "$QEMU_BIN"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Command:'
  printf ' %q' "$QEMU_BIN" "${QEMU_ARGS[@]}"
  printf '\n'
  exit 0
fi

exec "$QEMU_BIN" "${QEMU_ARGS[@]}"
