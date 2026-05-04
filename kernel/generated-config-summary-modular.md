# Generated modular kernel configs

Base config: `/root/kernel/kernel/example.config`

Profile: keep a single `bzImage` boot path aligned with the standard configs, while enabling real loadable module support via `CONFIG_MODULES` and `CONFIG_MODULE_UNLOAD`.

Boot-critical framebuffer and console settings stay aligned with the standard profile, including `SYSFB_SIMPLEFB`, `FB_EFI`, `FB_VESA`, `FB_SIMPLE`, and `FRAMEBUFFER_CONSOLE`.

Runtime-extensible coverage is emitted as modules for richer filesystems and less-common network adapters, so the modular outputs can use `modprobe`, `insmod`, and `rmmod` with an external module tree.

| Series | Real source | Output file |
| --- | --- | --- |
| `5.10` | `5.10.252` | `/root/kernel/kernel/linux-5.10-modular.config` |
| `5.15` | `5.15.202` | `/root/kernel/kernel/linux-5.15-modular.config` |
| `6.1` | `6.1.168` | `/root/kernel/kernel/linux-6.1-modular.config` |
| `6.6` | `6.6.134` | `/root/kernel/kernel/linux-6.6-modular.config` |
| `6.12` | `6.12.81` | `/root/kernel/kernel/linux-6.12-modular.config` |
| `6.18` | `6.18.22` | `/root/kernel/kernel/linux-6.18-modular.config` |
