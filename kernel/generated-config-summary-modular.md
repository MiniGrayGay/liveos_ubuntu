# Generated builtin-rich kernel configs

Base config: `/root/kernel/kernel/example.config`

Profile: keep the user-requested boot/storage/filesystem/network coverage builtin, while preserving the richer runtime and filesystem surface from the former modular profile.

Extra builtin surface: `KALLSYMS`, `IKCONFIG`, `PERF_EVENTS`, `BPF`, plus squashfs, fuse, overlayfs, NFS and CIFS built into the kernel image.

| Series | Real source | Output file |
| --- | --- | --- |
| `5.10` | `5.10.252` | `/root/kernel/kernel/linux-5.10-modular.config` |
| `5.15` | `5.15.202` | `/root/kernel/kernel/linux-5.15-modular.config` |
| `6.1` | `6.1.167` | `/root/kernel/kernel/linux-6.1-modular.config` |
| `6.6` | `6.6.133` | `/root/kernel/kernel/linux-6.6-modular.config` |
| `6.12` | `6.12.80` | `/root/kernel/kernel/linux-6.12-modular.config` |
| `6.18` | `6.18.21` | `/root/kernel/kernel/linux-6.18-modular.config` |
