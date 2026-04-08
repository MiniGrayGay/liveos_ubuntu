#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_CONFIG="${1:-$ROOT_DIR/kernel/example.config}"
SOURCE_ROOT="${2:-$ROOT_DIR/kernel}"
OUTPUT_DIR="${3:-$ROOT_DIR/kernel}"
SUMMARY_FILE="$OUTPUT_DIR/generated-config-summary.md"

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

normalize_symbol() {
  local line=$1
  line=${line#\# }
  line=${line#CONFIG_}
  line=${line%=*}
  line=${line% is not set}
  printf '%s\n' "$line"
}

prune_prefix() {
  local cfg=$1
  local prefix=$2
  shift 2
  local tmp
  tmp="$(mktemp)"
  awk -v prefix="$prefix" -v keep="$*" '
    BEGIN {
      split(keep, keep_items, " ");
      for (i in keep_items) {
        if (keep_items[i] != "") {
          allow[keep_items[i]] = 1;
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
      if (($0 ~ /^CONFIG_[A-Z0-9_]+=(y|m)$/ || $0 ~ /^# CONFIG_[A-Z0-9_]+ is not set$/) &&
          index(symbol, prefix) == 1 && !(symbol in allow)) {
        if (!(symbol in emitted)) {
          print "# CONFIG_" symbol " is not set";
          emitted[symbol] = 1;
        }
        next;
      }
      print;
    }
  ' "$cfg" >"$tmp"
  mv "$tmp" "$cfg"
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
    printf '# Output series: Linux/x86_64 %s\n' "$version"
    printf '# Local source tree: %s/%s\n' "$SOURCE_ROOT" "${VERSION_TO_SOURCE[$version]}"
    printf '# Actual source version: %s\n' "$real_version"
    cat "$target"
  } >"$tmp"
  mv "$tmp" "$target"
}

require_tool make
require_tool gcc
require_tool awk
require_tool mktemp

[ -f "$BASE_CONFIG" ] || die "base config not found: $BASE_CONFIG"
[ -d "$SOURCE_ROOT" ] || die "source root not found: $SOURCE_ROOT"
[ -d "$OUTPUT_DIR" ] || die "output dir not found: $OUTPUT_DIR"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/kernel-configs.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

for version in "${VERSIONS[@]}"; do
  src="$SOURCE_ROOT/${VERSION_TO_SOURCE[$version]}"
  out="$work_root/out-$version"
  cfg="$out/.config"
  target="$OUTPUT_DIR/linux-$version.config"

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

  # Baseline boot requirements.
  kc --disable MODULES
  kc --disable MODULE_UNLOAD
  kc --disable MODVERSIONS
  kc --disable KMOD
  kc --enable BLK_DEV_INITRD
  kc --enable DEVTMPFS
  kc --enable DEVTMPFS_MOUNT
  kc --enable TMPFS
  kc --enable UNIX
  kc --enable INET
  kc --enable PACKET
  kc --enable PCI
  kc --enable PCI_MSI
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

  # Keep the kernel image as small as possible and only accept initrd.zst.
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

  # Core bus support needed to load modules from initrd.
  kc --enable PCI
  kc --module ATA
  kc --enable ATA_ACPI
  kc --module SCSI
  kc --enable SCSI_PROC_FS
  kc --enable SCSI_SCAN_ASYNC
  kc --module BLK_DEV_SD
  kc --module BLK_DEV_SR
  kc --module CHR_DEV_SG
  kc --module BLK_DEV_NVME
  kc --module NVME_CORE
  kc --enable USB_SUPPORT
  kc --module USB
  kc --module USB_NET_DRIVERS
  kc --module USB_XHCI_HCD
  kc --module USB_EHCI_HCD
  kc --module USB_OHCI_HCD
  kc --module USB_UHCI_HCD
  kc --module USB_STORAGE
  kc --module USB_UAS
  kc --module VIRTIO
  kc --module VIRTIO_PCI
  kc --module VIRTIO_BLK
  kc --module SCSI_VIRTIO
  kc --enable XEN
  kc --enable XEN_PV
  kc --enable XEN_PVHVM
  kc --module XEN_BLKDEV_FRONTEND
  kc --module XEN_NETDEV_FRONTEND
  kc --enable HYPERV
  kc --module HYPERV_VMBUS
  kc --module HYPERV_STORAGE
  kc --module HYPERV_NET
  kc --module I2C
  kc --module PHYLIB
  kc --module PHYLINK

  # ATA / SATA / PATA keep-list.
  prune_prefix "$cfg" "ATA_" \
    ATA ATA_ACPI ATA_BMDMA ATA_GENERIC ATA_PIIX ATA_SFF
  prune_prefix "$cfg" "SATA_" \
    SATA_AHCI SATA_AHCI_PLATFORM
  prune_prefix "$cfg" "PATA_" \
    PATA_ACPI PATA_ALI PATA_AMD PATA_ARTOP PATA_ATIIXP PATA_CMD640_PCI \
    PATA_CMD64X PATA_CS5520 PATA_CS5530 PATA_CS5535 PATA_CS5536 PATA_CYPRESS \
    PATA_EFAR PATA_HPT366 PATA_HPT37X PATA_HPT3X2N PATA_HPT3X3 PATA_IT8213 \
    PATA_IT821X PATA_JMICRON PATA_LEGACY PATA_MARVELL PATA_MPIIX PATA_NETCELL \
    PATA_NINJA32 PATA_NS87410 PATA_NS87415 PATA_OLDPIIX PATA_OPTI PATA_PDC2027X \
    PATA_PDC_OLD PATA_RDC PATA_RZ1000 PATA_SCH PATA_SERVERWORKS PATA_SIL680 \
    PATA_SIS PATA_VIA PATA_WINBOND

  kc --module ATA
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

  # Keep only the SCSI core and requested virtualized storage support.
  prune_prefix "$cfg" "SCSI_" \
    SCSI SCSI_DMA SCSI_ISCSI_ATTRS SCSI_LOWLEVEL SCSI_MOD SCSI_NETLINK \
    SCSI_PROC_FS SCSI_SCAN_ASYNC SCSI_VIRTIO SCSI_WAIT_SCAN
  kc --module SCSI
  kc --module SCSI_MOD
  kc --module SCSI_VIRTIO
  kc --module HYPERV_STORAGE
  kc --module BLK_DEV_NVME
  kc --module NVME_CORE

  # File systems explicitly requested by the user.
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
  kc --disable JFS_FS
  kc --disable OCFS2_FS
  kc --disable GFS2_FS
  kc --disable SQUASHFS
  kc --disable NFS_FS
  kc --disable CIFS
  kc --disable SMB_SERVER
  kc --disable FUSE_FS

  kc --disable BTRFS_FS_RUN_SANITY_TESTS
  kc --disable BTRFS_FS_CHECK_INTEGRITY
  kc --disable BTRFS_DEBUG
  kc --disable BTRFS_ASSERT
  kc --disable BTRFS_EXPERIMENTAL
  kc --disable F2FS_FS_COMPRESSION
  kc --disable F2FS_FS_LZO
  kc --disable F2FS_FS_LZORLE
  kc --disable F2FS_FS_LZ4
  kc --disable F2FS_FS_LZ4HC
  kc --disable F2FS_FS_ZSTD

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

  # Network driver pruning by vendor menu.
  prune_prefix "$cfg" "NET_VENDOR_" \
    NET_VENDOR_AMAZON NET_VENDOR_AQUANTIA NET_VENDOR_ATHEROS \
    NET_VENDOR_BROADCOM NET_VENDOR_INTEL NET_VENDOR_MELLANOX \
    NET_VENDOR_MICROSOFT NET_VENDOR_REALTEK

  # Requested physical, virtual and USB ethernet coverage.
  kc --module E1000
  kc --module E1000E
  kc --disable E1000E_HWTS
  kc --module IGB
  kc --disable IGB_HWMON
  kc --disable IGB_DCA
  kc --module IGBVF
  kc --module IXGBE
  kc --disable IXGBE_HWMON
  kc --disable IXGBE_DCA
  kc --disable IXGBE_DCB
  kc --disable IXGBE_IPSEC
  kc --module IXGBEVF
  kc --disable IXGBEVF_IPSEC
  kc --module IGC
  kc --disable IGC_HWMON
  kc --module R8169
  kc --disable R8169_LEDS
  kc --module TIGON3
  kc --disable TIGON3_HWMON
  kc --module BNX2
  kc --disable CNIC
  kc --module BNX2X
  kc --disable BNX2X_SRIOV
  kc --module BNXT
  kc --disable BNXT_SRIOV
  kc --disable BNXT_FLOWER_OFFLOAD
  kc --disable BNXT_DCB
  kc --disable BNXT_HWMON
  kc --module ATL1E
  kc --module ATL1C
  kc --module AQTION
  kc --module MLX4_EN
  kc --module MLX5_CORE
  kc --disable MLX4_EN_DCB
  kc --enable MLX5_CORE_EN
  kc --disable MLX5_CORE_EN_DCB
  kc --module ENA_ETHERNET
  kc --module VIRTIO_NET
  kc --module VMXNET3
  kc --module XEN_NETDEV_FRONTEND
  kc --module HYPERV_NET
  kc --module REALTEK_PHY
  kc --module MOTORCOMM_PHY
  kc --module MARVELL_PHY
  kc --module SFP

  # Modern USB LAN adapters.
  prune_prefix "$cfg" "USB_NET_" \
    USB_NET_DRIVERS USB_NET_AQC111 USB_NET_AX88179_178A USB_NET_AX8817X \
    USB_NET_CDCETHER USB_NET_CDC_EEM USB_NET_CDC_MBIM USB_NET_CDC_NCM
  kc --module USB_USBNET
  kc --module USB_RTL8152
  kc --disable USB_RTL8150
  kc --module USB_LAN78XX
  kc --module USB_NET_AX8817X
  kc --module USB_NET_AX88179_178A
  kc --module USB_NET_AQC111
  kc --module USB_NET_CDCETHER
  kc --module USB_NET_CDC_EEM
  kc --module USB_NET_CDC_NCM
  kc --module USB_NET_CDC_MBIM
  kc --disable USB_NET_QMI_WWAN

  # Trim obvious non-target subsystems.
  for sym in \
    WLAN CFG80211 MAC80211 RFKILL BT SOUND MEDIA_SUPPORT DRM FB NFC CAN \
    HAMRADIO ISDN USB_PRINTER INPUT_JOYSTICK INPUT_TABLET INPUT_TOUCHSCREEN \
    KUNIT RUNTIME_TESTING_MENU DEBUG_KERNEL DEBUG_INFO FTRACE FUNCTION_TRACER \
    STACK_TRACER KGDB FIREWIRE USB_GADGET STAGING COMEDI TV; do
    kc --disable "$sym"
  done

  # Keep the generated config size-oriented rather than perf-oriented.
  kc --enable CC_OPTIMIZE_FOR_SIZE
  kc --disable CC_OPTIMIZE_FOR_PERFORMANCE
  kc --disable PRINTK_TIME
  kc --disable IKCONFIG
  kc --disable IKHEADERS
  kc --disable KALLSYMS
  kc --disable PERF_EVENTS
  kc --disable BPF
  kc --disable BPF_SYSCALL
  kc --disable KCOV
  kc --disable KASAN
  kc --disable UBSAN
  kc --disable SLUB_DEBUG
  kc --set-val SERIAL_8250_NR_UARTS 4
  kc --set-val SERIAL_8250_RUNTIME_UARTS 4

  force_builtin "$cfg" \
    TTY VT SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_8250_PNP SERIAL_EARLYCON \
    ATA ATA_PIIX ATA_GENERIC SATA_AHCI SATA_AHCI_PLATFORM \
    PATA_ACPI PATA_ALI PATA_AMD PATA_ARTOP PATA_ATIIXP PATA_CMD640_PCI \
    PATA_CMD64X PATA_CS5520 PATA_CS5530 PATA_CS5535 PATA_CS5536 PATA_CYPRESS \
    PATA_EFAR PATA_HPT366 PATA_HPT37X PATA_HPT3X2N PATA_HPT3X3 PATA_IT8213 \
    PATA_IT821X PATA_JMICRON PATA_LEGACY PATA_MARVELL PATA_MPIIX PATA_NETCELL \
    PATA_NINJA32 PATA_NS87410 PATA_NS87415 PATA_OLDPIIX PATA_OPTI PATA_PDC2027X \
    PATA_PDC_OLD PATA_RDC PATA_RZ1000 PATA_SCH PATA_SERVERWORKS PATA_SIL680 \
    PATA_SIS PATA_VIA PATA_WINBOND SCSI SCSI_MOD BLK_DEV_SD BLK_DEV_SR CHR_DEV_SG \
    SCSI_VIRTIO BLK_DEV_NVME NVME_CORE USB USB_NET_DRIVERS USB_XHCI_HCD \
    USB_EHCI_HCD USB_OHCI_HCD USB_UHCI_HCD USB_STORAGE USB_UAS VIRTIO VIRTIO_PCI \
    VIRTIO_BLK XEN_BLKDEV_FRONTEND XEN_NETDEV_FRONTEND HYPERV_VMBUS HYPERV_STORAGE \
    HYPERV_NET I2C PHYLIB PHYLINK EXT2_FS EXT4_FS XFS_FS BTRFS_FS NILFS2_FS \
    F2FS_FS ISO9660_FS UDF_FS MSDOS_FS VFAT_FS E1000 E1000E IGB IGBVF IXGBE IXGBEVF \
    IGC R8169 TIGON3 BNX2 BNX2X BNXT ATL1E ATL1C AQTION MLX4_EN MLX5_CORE \
    ENA_ETHERNET VIRTIO_NET VMXNET3 REALTEK_PHY MOTORCOMM_PHY MARVELL_PHY SFP \
    USB_USBNET USB_RTL8152 USB_LAN78XX USB_NET_AX8817X USB_NET_AX88179_178A \
    USB_NET_AQC111 USB_NET_CDCETHER USB_NET_CDC_EEM USB_NET_CDC_NCM USB_NET_CDC_MBIM

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
  printf '# Generated kernel configs\n\n'
  printf 'Base config: `%s`\n\n' "$BASE_CONFIG"
  printf 'Disabled large subsystems across all variants: WLAN, Bluetooth, sound, media, DRM/fbdev, NFC, CAN, hamradio, ISDN, USB printer, tablet/joystick/touch input, tests, tracing/debug.\n\n'
  printf 'Enabled boot-critical features across all variants: `EFI`, `EFI_STUB`, `EFI_PARTITION`, `EFIVAR_FS`, `BLK_DEV_INITRD`, `RD_ZSTD`, `IP_PNP`, `IP_PNP_DHCP`, `IP_PNP_BOOTP`, `ISCSI_BOOT_SYSFS`.\n\n'
  printf 'Enabled requested storage coverage as built-ins: ATA/AHCI/PATA, SCSI, NVMe, USB storage/UAS, virtio, Xen frontend, Hyper-V storage.\n\n'
  printf 'Enabled requested network coverage as built-ins: Intel, Realtek, Broadcom, Atheros, Mellanox, Amazon ENA, Aquantia AQTION, virtio, vmxnet3, Xen frontend, Hyper-V, modern USB LAN, and common PHY/SFP support.\n\n'
  printf '| Series | Real source | Output file |\n'
  printf '| --- | --- | --- |\n'
  for version in "${VERSIONS[@]}"; do
    printf '| `%s` | `%s` | `%s/linux-%s.config` |\n' \
      "$version" "${VERSION_TO_REAL[$version]}" "$OUTPUT_DIR" "$version"
  done
} >"$SUMMARY_FILE"

printf 'Generated configs in %s\n' "$OUTPUT_DIR"
printf 'Summary written to %s\n' "$SUMMARY_FILE"
