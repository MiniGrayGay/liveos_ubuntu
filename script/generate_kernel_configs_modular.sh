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

force_builtin() {
  local cfg=$1
  shift
  local tmp
  tmp="$(mktemp)"
  awk -v symbols="$*" '
    BEGIN {
      split(symbols, items, " ");
      for (i in items) {
        if (items[i] != "") {
          want[items[i]] = 1;
        }
      }
    }
    function symbol_name(line, out) {
      out = line;
      sub(/^# /, "", out);
      sub(/^CONFIG_/, "", out);
      sub(/=.*/, "", out);
      sub(/ is not set$/, "", out);
      return out;
    }
    {
      symbol = symbol_name($0);
      if (symbol in want) {
        if (!(symbol in emitted)) {
          print "CONFIG_" symbol "=y";
          emitted[symbol] = 1;
        }
        next;
      }
      print;
    }
    END {
      for (symbol in want) {
        if (!(symbol in emitted)) {
          print "CONFIG_" symbol "=y";
        }
      }
    }
  ' "$cfg" >"$tmp"
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

  if [[ -f "$seed_config" ]]; then
    cp "$seed_config" "$cfg"
  else
    seed_config="$BASE_CONFIG"
    cp "$BASE_CONFIG" "$cfg"
  fi

  sed -i \
    -e '/^CONFIG_BASE_SMALL=/d' \
    -e '/^CONFIG_KASAN_STACK=/d' \
    "$cfg"

  kc() {
    "$src/scripts/config" --file "$cfg" "$@"
  }

  # Keep the standard boot path intact while turning on real loadable modules.
  # These target trees do not expose a standalone CONFIG_KMOD knob, so
  # CONFIG_MODULES / CONFIG_MODULE_UNLOAD are the portable controls here.
  kc --enable MODULES
  kc --enable MODULE_UNLOAD
  kc --disable MODULE_UNLOAD_TAINT_TRACKING
  kc --disable MODVERSIONS
  kc --enable BLOCK
  kc --enable HOTPLUG
  kc --enable BLK_DEV_INITRD
  kc --enable DEVTMPFS
  kc --enable DEVTMPFS_MOUNT
  kc --enable TMPFS
  kc --enable TMPFS_POSIX_ACL
  kc --enable UNIX
  kc --enable INET
  kc --enable PACKET
  kc --enable NET
  kc --enable PCI
  kc --enable PCI_MSI
  kc --enable EFI
  kc --enable EFI_STUB
  kc --enable EFI_PARTITION
  kc --enable EFIVAR_FS
  kc --enable SYSFB
  kc --enable SYSFB_SIMPLEFB
  kc --enable VT
  kc --enable TTY
  kc --enable SERIAL_8250
  kc --enable SERIAL_8250_CONSOLE
  kc --enable SERIAL_8250_PNP
  kc --enable SERIAL_EARLYCON
  kc --enable FB
  kc --enable FB_EFI
  kc --enable FB_VESA
  kc --enable FB_SIMPLE
  kc --enable FRAMEBUFFER_CONSOLE
  kc --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
  kc --enable FRAMEBUFFER_CONSOLE_ROTATION
  kc --enable IP_PNP
  kc --enable IP_PNP_DHCP
  kc --enable IP_PNP_BOOTP
  kc --disable IP_PNP_RARP
  kc --enable ISCSI_BOOT_SYSFS
  kc --enable FW_LOADER
  kc --disable FIRMWARE_IN_KERNEL
  kc --set-str EXTRA_FIRMWARE ""
  kc --set-str EXTRA_FIRMWARE_DIR ""

  # Keep the single kernel image format identical to the standard profile.
  kc --enable KERNEL_XZ
  kc --disable KERNEL_GZIP
  kc --disable KERNEL_BZIP2
  kc --disable KERNEL_LZMA
  kc --disable KERNEL_LZO
  kc --disable KERNEL_LZ4
  kc --disable KERNEL_ZSTD
  kc --enable RD_ZSTD
  kc --disable RD_GZIP
  kc --disable RD_BZIP2
  kc --disable RD_LZMA
  kc --disable RD_XZ
  kc --disable RD_LZO
  kc --disable RD_LZ4

  # Core boot/storage/network coverage stays builtin so one bzImage can boot
  # with arbitrary initrd contents, while richer runtime coverage stays modular.
  force_builtin "$cfg" \
    TTY VT SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_8250_PNP SERIAL_EARLYCON \
    FB FB_EFI FB_VESA FB_SIMPLE FRAMEBUFFER_CONSOLE \
    FRAMEBUFFER_CONSOLE_DETECT_PRIMARY FRAMEBUFFER_CONSOLE_ROTATION \
    ATA ATA_PIIX ATA_GENERIC SATA_AHCI SATA_AHCI_PLATFORM \
    PATA_ACPI PATA_ALI PATA_AMD PATA_ARTOP PATA_ATIIXP PATA_CMD640_PCI \
    PATA_CMD64X PATA_CS5520 PATA_CS5530 PATA_CS5535 PATA_CS5536 PATA_CYPRESS \
    PATA_EFAR PATA_HPT366 PATA_HPT37X PATA_HPT3X2N PATA_HPT3X3 PATA_IT8213 \
    PATA_IT821X PATA_JMICRON PATA_LEGACY PATA_MARVELL PATA_MPIIX PATA_NETCELL \
    PATA_NINJA32 PATA_NS87410 PATA_NS87415 PATA_OLDPIIX PATA_OPTI \
    PATA_PDC2027X PATA_PDC_OLD PATA_RDC PATA_RZ1000 PATA_SCH \
    PATA_SERVERWORKS PATA_SIL680 PATA_SIS PATA_VIA PATA_WINBOND \
    SCSI SCSI_MOD BLK_DEV_SD BLK_DEV_SR CHR_DEV_SG SCSI_VIRTIO \
    BLK_DEV_NVME NVME_CORE USB USB_XHCI_HCD USB_EHCI_HCD USB_OHCI_HCD \
    USB_UHCI_HCD USB_STORAGE USB_UAS VIRTIO VIRTIO_PCI VIRTIO_BLK \
    XEN_BLKDEV_FRONTEND XEN_NETDEV_FRONTEND HYPERV_VMBUS HYPERV_STORAGE \
    HYPERV_NET I2C HWMON PHYLIB PHYLINK SFP EXT2_FS EXT4_FS EXT4_USE_FOR_EXT2 \
    ISO9660_FS MSDOS_FS VFAT_FS E1000 E1000E IGB R8169 TIGON3 VIRTIO_NET \
    VMXNET3 REALTEK_PHY MOTORCOMM_PHY MARVELL_PHY

  # Filesystems that are useful at runtime but not required for the generic
  # initrd boot path become true loadable modules.
  kc --module XFS_FS
  kc --module BTRFS_FS
  kc --module NILFS2_FS
  kc --module F2FS_FS
  kc --module UDF_FS
  kc --module SQUASHFS
  kc --module FUSE_FS
  kc --module OVERLAY_FS
  kc --module NFS_FS
  kc --module CIFS

  if [[ "$version" != "6.18" ]]; then
    kc --module EXT3_FS
    kc --module REISERFS_FS
    kc --enable REISERFS_FS_XATTR
    kc --enable REISERFS_FS_POSIX_ACL
    kc --enable REISERFS_FS_SECURITY
  else
    kc --disable EXT3_FS
    kc --disable REISERFS_FS
  fi

  if [[ "$version" == "5.10" ]]; then
    kc --module NTFS_FS
    kc --disable NTFS3_FS
  else
    kc --module NTFS3_FS
    kc --disable NTFS_FS
  fi

  # Less common high-end NICs and USB LAN adapters stay modular.
  kc --module IGBVF
  kc --module IXGBE
  kc --module IXGBEVF
  kc --module IGC
  kc --module BNX2
  kc --module BNX2X
  kc --module BNXT
  kc --module ATL1E
  kc --module ATL1C
  kc --module AQTION
  kc --module MLX4_EN
  kc --module MLX5_CORE
  kc --enable MLX5_CORE_EN
  kc --module ENA_ETHERNET
  kc --module USB_NET_DRIVERS
  kc --module USB_USBNET
  kc --module USB_RTL8152
  kc --module USB_LAN78XX
  kc --module USB_NET_AX8817X
  kc --module USB_NET_AX88179_178A
  kc --module USB_NET_AQC111
  kc --module USB_NET_CDCETHER
  kc --module USB_NET_CDC_EEM
  kc --module USB_NET_CDC_NCM
  kc --module USB_NET_CDC_MBIM

  # Keep the richer runtime/debug surface from the old modular profile.
  kc --enable KALLSYMS
  kc --enable IKCONFIG
  kc --enable IKCONFIG_PROC
  kc --enable PERF_EVENTS
  kc --enable BPF
  kc --enable BPF_SYSCALL
  kc --set-val SERIAL_8250_NR_UARTS 4
  kc --set-val SERIAL_8250_RUNTIME_UARTS 4

  make -s -C "$src" O="$out" ARCH=x86 olddefconfig
  cp "$cfg" "$target"
  prepend_header "$target" "$version" "${VERSION_TO_REAL[$version]}" "$seed_config"
  chmod 0644 "$target"
done

{
  printf '# Generated modular kernel configs\n\n'
  printf 'Base config: `%s`\n\n' "$BASE_CONFIG"
  printf 'Profile: keep a single `bzImage` boot path aligned with the standard configs, while enabling real loadable module support via `CONFIG_MODULES` and `CONFIG_MODULE_UNLOAD`.\n\n'
  printf 'Boot-critical framebuffer and console settings stay aligned with the standard profile, including `SYSFB_SIMPLEFB`, `FB_EFI`, `FB_VESA`, `FB_SIMPLE`, and `FRAMEBUFFER_CONSOLE`.\n\n'
  printf 'Runtime-extensible coverage is emitted as modules for richer filesystems and less-common network adapters, so the modular outputs can use `modprobe`, `insmod`, and `rmmod` with an external module tree.\n\n'
  printf '| Series | Real source | Output file |\n'
  printf '| --- | --- | --- |\n'
  for version in "${KERNEL_SERIES[@]}"; do
    printf '| `%s` | `%s` | `%s/linux-%s-modular.config` |\n' \
      "$version" "${VERSION_TO_REAL[$version]}" "$OUTPUT_DIR" "$version"
  done
} >"$SUMMARY_FILE"

printf 'Generated modular configs in %s\n' "$OUTPUT_DIR"
printf 'Summary written to %s\n' "$SUMMARY_FILE"
