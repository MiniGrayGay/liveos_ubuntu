# Generated modular kernel configs

Base config: `/root/kernel/kernel/example.config`

Profile: derive directly from the standard configs and keep a single `bzImage` boot path, while enabling only the module syscalls needed by `lsmod`, `modprobe`, `insmod`, and `rmmod` via `CONFIG_MODULES` and `CONFIG_MODULE_UNLOAD`.

No selected driver or filesystem is emitted as `=m`; generated configs are checked to ensure they do not require an external module tree.

| Series | Real source | Output file |
| --- | --- | --- |
| `5.10` | `5.10.258` | `/root/kernel/kernel/linux-5.10-modular.config` |
| `5.15` | `5.15.209` | `/root/kernel/kernel/linux-5.15-modular.config` |
| `6.1` | `6.1.175` | `/root/kernel/kernel/linux-6.1-modular.config` |
| `6.6` | `6.6.142` | `/root/kernel/kernel/linux-6.6-modular.config` |
| `6.12` | `6.12.92` | `/root/kernel/kernel/linux-6.12-modular.config` |
| `6.18` | `6.18.34` | `/root/kernel/kernel/linux-6.18-modular.config` |
