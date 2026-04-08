# Generated kernel configs

Base config: `/root/kernel/kernel/example.config`

Disabled large subsystems across all variants: WLAN, Bluetooth, sound, media, DRM/fbdev, NFC, CAN, hamradio, ISDN, USB printer, tablet/joystick/touch input, tests, tracing/debug.

Enabled boot-critical features across all variants: `EFI`, `EFI_STUB`, `EFI_PARTITION`, `EFIVAR_FS`, `BLK_DEV_INITRD`, `RD_ZSTD`, `IP_PNP`, `IP_PNP_DHCP`, `IP_PNP_BOOTP`, `ISCSI_BOOT_SYSFS`.

Enabled requested storage coverage as built-ins: ATA/AHCI/PATA, SCSI, NVMe, USB storage/UAS, virtio, Xen frontend, Hyper-V storage.

Enabled requested network coverage as built-ins: Intel, Realtek, Broadcom, Atheros, Mellanox, Amazon ENA, Aquantia AQTION, virtio, vmxnet3, Xen frontend, Hyper-V, modern USB LAN, and common PHY/SFP support.

| Series | Real source | Output file |
| --- | --- | --- |
| `5.10` | `5.10.252` | `/root/kernel/kernel/linux-5.10.config` |
| `5.15` | `5.15.202` | `/root/kernel/kernel/linux-5.15.config` |
| `6.1` | `6.1.167` | `/root/kernel/kernel/linux-6.1.config` |
| `6.6` | `6.6.133` | `/root/kernel/kernel/linux-6.6.config` |
| `6.12` | `6.12.80` | `/root/kernel/kernel/linux-6.12.config` |
| `6.18` | `6.18.21` | `/root/kernel/kernel/linux-6.18.config` |
