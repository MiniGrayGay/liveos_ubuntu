#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_CONFIG="${1:-$ROOT_DIR/kernel/example.config}"
SOURCE_ROOT="${2:-$ROOT_DIR/kernel}"
OUTPUT_DIR="${3:-$ROOT_DIR/kernel}"
SUMMARY_FILE="$OUTPUT_DIR/generated-config-summary-modular.md"

declare -A VERSION_TO_SOURCE=(
  ["5.10"]="linux-5.10.252"
  ["5.15"]="linux-5.15.202"
  ["6.1"]="linux-6.1.167"
  ["6.6"]="linux-6.6.133"
  ["6.12"]="linux-6.12.80"
  ["6.18"]="linux-6.18.21"
)

declare -A VERSION_TO_REAL=(
  ["5.10"]="5.10.252"
  ["5.15"]="5.15.202"
  ["6.1"]="6.1.167"
  ["6.6"]="6.6.133"
  ["6.12"]="6.12.80"
  ["6.18"]="6.18.21"
)

VERSIONS=(5.10 5.15 6.1 6.6 6.12 6.18)

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
  local tmp
  tmp="$(mktemp)"
  {
    printf '# Generated from %s\n' "$BASE_CONFIG"
    printf '# Output profile: modular\n'
    printf '# Output series: Linux/x86_64 %s\n' "$version"
    printf '# Local source tree: %s/%s\n' "$SOURCE_ROOT" "${VERSION_TO_SOURCE[$version]}"
    printf '# Actual source version: %s\n' "$real_version"
    cat "$target"
  } >"$tmp"
  mv "$tmp" "$target"
}

require_tool make
require_tool gcc
require_tool mktemp

[ -f "$BASE_CONFIG" ] || die "base config not found: $BASE_CONFIG"
[ -d "$SOURCE_ROOT" ] || die "source root not found: $SOURCE_ROOT"
[ -d "$OUTPUT_DIR" ] || die "output dir not found: $OUTPUT_DIR"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/kernel-configs-modular.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

for version in "${VERSIONS[@]}"; do
  src="$SOURCE_ROOT/${VERSION_TO_SOURCE[$version]}"
  out="$work_root/out-$version"
  cfg="$out/.config"
  target="$OUTPUT_DIR/linux-$version-modular.config"

  [ -d "$src" ] || die "missing source tree for $version: $src"
  [ -x "$src/scripts/config" ] || die "missing scripts/config in $src"

  mkdir -p "$out"
  cp "$BASE_CONFIG" "$cfg"
  sed -i \
    -e '/^CONFIG_BASE_SMALL=/d' \
    -e '/^CONFIG_KASAN_STACK=/d' \
    "$cfg"

  kc() {
    "$src/scripts/config" --file "$cfg" "$@"
  }

  # Make the profile explicitly module-friendly.
  kc --disable MODULES
  kc --disable KMOD
  kc --disable MODULE_UNLOAD
  kc --disable MODULE_UNLOAD_TAINT_TRACKING
  kc --disable MODVERSIONS
  kc --enable BLOCK
  kc --enable HOTPLUG
  kc --enable BLK_DEV_INITRD
  kc --enable DEVTMPFS
  kc --enable DEVTMPFS_MOUNT
  kc --enable TMPFS
  kc --enable TMPFS_POSIX_ACL

  # Boot path requirements remain identical to the slim profile.
  kc --enable EFI
  kc --enable EFI_STUB
  kc --enable EFI_PARTITION
  kc --enable EFIVAR_FS
  kc --enable VT
  kc --enable TTY
  kc --enable SERIAL_8250
  kc --enable SERIAL_8250_CONSOLE
  kc --enable SERIAL_8250_PNP
  kc --enable SERIAL_EARLYCON
  kc --enable IP_PNP
  kc --enable IP_PNP_DHCP
  kc --enable IP_PNP_BOOTP
  kc --disable IP_PNP_RARP
  kc --enable ISCSI_BOOT_SYSFS
  kc --enable FW_LOADER
  kc --disable FIRMWARE_IN_KERNEL
  kc --set-str EXTRA_FIRMWARE ""
  kc --set-str EXTRA_FIRMWARE_DIR ""

  # Keep the compressed kernel image small, but stay module-friendly overall.
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

  # Core infrastructure needed to load many modules at runtime.
  kc --enable PCI
  kc --enable PCI_MSI
  kc --enable UNIX
  kc --enable INET
  kc --enable PACKET
  kc --enable NET
  kc --module I2C
  kc --module HWMON
  kc --module PHYLIB
  kc --module PHYLINK
  kc --module SFP
  kc --enable CRC32
  kc --enable ZLIB_INFLATE

  # Storage and block-device coverage.
  kc --module ATA
  kc --enable ATA_ACPI
  kc --enable ATA_SFF
  kc --enable ATA_BMDMA
  kc --module ATA_PIIX
  kc --module ATA_GENERIC
  kc --module SATA_AHCI
  kc --module SATA_AHCI_PLATFORM
  for sym in \
    PATA_ACPI PATA_ALI PATA_AMD PATA_ARTOP PATA_ATIIXP PATA_CMD640_PCI \
    PATA_CMD64X PATA_CS5520 PATA_CS5530 PATA_CS5535 PATA_CS5536 PATA_CYPRESS \
    PATA_EFAR PATA_HPT366 PATA_HPT37X PATA_HPT3X2N PATA_HPT3X3 PATA_IT8213 \
    PATA_IT821X PATA_JMICRON PATA_LEGACY PATA_MARVELL PATA_MPIIX PATA_NETCELL \
    PATA_NINJA32 PATA_NS87410 PATA_NS87415 PATA_OLDPIIX PATA_OPTI PATA_PDC2027X \
    PATA_PDC_OLD PATA_RDC PATA_RZ1000 PATA_SCH PATA_SERVERWORKS PATA_SIL680 \
    PATA_SIS PATA_VIA PATA_WINBOND; do
    kc --module "$sym"
  done
  kc --module SCSI
  kc --enable SCSI_PROC_FS
  kc --enable SCSI_SCAN_ASYNC
  kc --module SCSI_MOD
  kc --module BLK_DEV_SD
  kc --module BLK_DEV_SR
  kc --module CHR_DEV_SG
  kc --module SCSI_VIRTIO
  kc --module BLK_DEV_NVME
  kc --module NVME_CORE
  kc --enable USB_SUPPORT
  kc --module USB
  kc --module USB_XHCI_HCD
  kc --module USB_EHCI_HCD
  kc --module USB_OHCI_HCD
  kc --module USB_UHCI_HCD
  kc --module USB_STORAGE
  kc --module USB_UAS
  kc --module VIRTIO
  kc --module VIRTIO_PCI
  kc --module VIRTIO_BLK
  kc --enable XEN
  kc --enable XEN_PV
  kc --enable XEN_PVHVM
  kc --module XEN_BLKDEV_FRONTEND
  kc --enable HYPERV
  kc --module HYPERV_VMBUS
  kc --module HYPERV_STORAGE

  # Requested file systems, plus a few common module-friendly extras.
  kc --module EXT2_FS
  kc --module EXT4_FS
  kc --enable EXT4_USE_FOR_EXT2
  kc --module XFS_FS
  kc --module BTRFS_FS
  kc --module NILFS2_FS
  kc --module F2FS_FS
  kc --module ISO9660_FS
  kc --module UDF_FS
  kc --module MSDOS_FS
  kc --module VFAT_FS
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
  fi

  if [[ "$version" == "5.10" ]]; then
    kc --module NTFS_FS
  else
    kc --module NTFS3_FS
    kc --disable NTFS_FS
  fi

  # Requested network coverage, leaving the rest of the baseline intact.
  kc --module E1000
  kc --module E1000E
  kc --module IGB
  kc --module IGBVF
  kc --module IXGBE
  kc --module IXGBEVF
  kc --module IGC
  kc --module R8169
  kc --module TIGON3
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
  kc --module VIRTIO_NET
  kc --module VMXNET3
  kc --module XEN_NETDEV_FRONTEND
  kc --module HYPERV_NET
  kc --module REALTEK_PHY
  kc --module MOTORCOMM_PHY
  kc --module MARVELL_PHY

  # Modern USB LAN adapters.
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

  # Keep a much more flexible debugging / runtime surface than the slim build.
  kc --enable KALLSYMS
  kc --enable IKCONFIG
  kc --enable IKCONFIG_PROC
  kc --enable PERF_EVENTS
  kc --enable BPF
  kc --enable BPF_SYSCALL
  kc --set-val SERIAL_8250_NR_UARTS 4
  kc --set-val SERIAL_8250_RUNTIME_UARTS 4

  force_builtin "$cfg" \
    TTY VT SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_8250_PNP SERIAL_EARLYCON \
    I2C HWMON PHYLIB PHYLINK SFP ATA ATA_PIIX ATA_GENERIC SATA_AHCI \
    SATA_AHCI_PLATFORM PATA_ACPI PATA_ALI PATA_AMD PATA_ARTOP PATA_ATIIXP \
    PATA_CMD640_PCI PATA_CMD64X PATA_CS5520 PATA_CS5530 PATA_CS5535 \
    PATA_CS5536 PATA_CYPRESS PATA_EFAR PATA_HPT366 PATA_HPT37X PATA_HPT3X2N \
    PATA_HPT3X3 PATA_IT8213 PATA_IT821X PATA_JMICRON PATA_LEGACY PATA_MARVELL \
    PATA_MPIIX PATA_NETCELL PATA_NINJA32 PATA_NS87410 PATA_NS87415 \
    PATA_OLDPIIX PATA_OPTI PATA_PDC2027X PATA_PDC_OLD PATA_RDC PATA_RZ1000 \
    PATA_SCH PATA_SERVERWORKS PATA_SIL680 PATA_SIS PATA_VIA PATA_WINBOND \
    SCSI SCSI_MOD BLK_DEV_SD BLK_DEV_SR CHR_DEV_SG SCSI_VIRTIO BLK_DEV_NVME \
    NVME_CORE USB USB_XHCI_HCD USB_EHCI_HCD USB_OHCI_HCD USB_UHCI_HCD \
    USB_STORAGE USB_UAS VIRTIO VIRTIO_PCI VIRTIO_BLK XEN_BLKDEV_FRONTEND \
    HYPERV_VMBUS HYPERV_STORAGE EXT2_FS EXT4_FS XFS_FS BTRFS_FS NILFS2_FS \
    F2FS_FS ISO9660_FS UDF_FS MSDOS_FS VFAT_FS SQUASHFS FUSE_FS OVERLAY_FS \
    NFS_FS CIFS E1000 E1000E IGB IGBVF IXGBE IXGBEVF IGC R8169 TIGON3 BNX2 \
    BNX2X BNXT ATL1E ATL1C AQTION MLX4_EN MLX5_CORE ENA_ETHERNET VIRTIO_NET \
    VMXNET3 XEN_NETDEV_FRONTEND HYPERV_NET REALTEK_PHY MOTORCOMM_PHY \
    MARVELL_PHY USB_NET_DRIVERS USB_USBNET USB_RTL8152 USB_LAN78XX \
    USB_NET_AX8817X USB_NET_AX88179_178A USB_NET_AQC111 USB_NET_CDCETHER \
    USB_NET_CDC_EEM USB_NET_CDC_NCM USB_NET_CDC_MBIM IKCONFIG

  if [[ "$version" != "6.18" ]]; then
    force_builtin "$cfg" EXT3_FS REISERFS_FS
  fi

  if [[ "$version" == "5.10" ]]; then
    force_builtin "$cfg" NTFS_FS
  else
    force_builtin "$cfg" NTFS3_FS
  fi

  make -s -C "$src" O="$out" ARCH=x86 olddefconfig
  cp "$cfg" "$target"
  prepend_header "$target" "$version" "${VERSION_TO_REAL[$version]}"
  chmod 0644 "$target"
done

{
  printf '# Generated builtin-rich kernel configs\n\n'
  printf 'Base config: `%s`\n\n' "$BASE_CONFIG"
  printf 'Profile: keep the user-requested boot/storage/filesystem/network coverage builtin, while preserving the richer runtime and filesystem surface from the former modular profile.\n\n'
  printf 'Extra builtin surface: `KALLSYMS`, `IKCONFIG`, `PERF_EVENTS`, `BPF`, plus squashfs, fuse, overlayfs, NFS and CIFS built into the kernel image.\n\n'
  printf '| Series | Real source | Output file |\n'
  printf '| --- | --- | --- |\n'
  for version in "${VERSIONS[@]}"; do
    printf '| `%s` | `%s` | `%s/linux-%s-modular.config` |\n' \
      "$version" "${VERSION_TO_REAL[$version]}" "$OUTPUT_DIR" "$version"
  done
} >"$SUMMARY_FILE"

printf 'Generated modular configs in %s\n' "$OUTPUT_DIR"
printf 'Summary written to %s\n' "$SUMMARY_FILE"
