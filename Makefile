SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR := $(CURDIR)
OUTPUT_DIR := $(ROOT_DIR)/output

JOBS ?= $(shell nproc)
KERNEL ?= 7.0.10
KERNEL_INPUTS ?= $(KERNEL)
SETUP_FLAGS ?= -y
CONFIG_ARGS ?=
QEMU_ARGS ?=
ISO_ARGS ?=
UBUNTU_BASE_VERSION ?= 26.04
UBUNTU_BASE_ARCH ?= amd64
ISO_KERNEL ?= 6.18
ISO_KERNEL_OUTPUT ?= $(ISO_KERNEL)
ISO_UBUNTU_BASE_VERSION ?= 26.04
SETUP_UBUNTU_BASE_TARBALL ?=

KNOWN_TARGETS := \
	help scripts logs status \
	configs configs-mod configs-all \
	kernel kernel-mod kernel-both kernel-all \
	busybox-static busybox-mipsel-static dropbear-static sftp-static static-tools ensure-static-tools \
	ubuntu-base setup-sysroot setup-sysroot-ask setup-sysroot-keep export-sysroot initrd sysroot rootfs \
	grub4dos-framework iso pack-iso \
	qemu qemu-gui qemu-dry-run \
	clean clean-static clean-rootfs
KERNEL_POSITIONAL_TARGETS := kernel kernel-mod kernel-both
KERNEL_ARG_GOALS :=
SYSROOT_POSITIONAL_TARGETS := sysroot ubuntu-base
SYSROOT_ARG_GOALS :=

ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(KERNEL_POSITIONAL_TARGETS)),)
KERNEL_ARG_GOALS := $(filter-out $(KNOWN_TARGETS),$(MAKECMDGOALS))
ifneq ($(KERNEL_ARG_GOALS),)
KERNEL_INPUTS := $(KERNEL_ARG_GOALS)
endif
endif

ifneq ($(filter $(firstword $(MAKECMDGOALS)),$(SYSROOT_POSITIONAL_TARGETS)),)
SYSROOT_ARG_GOALS := $(filter-out $(KNOWN_TARGETS),$(MAKECMDGOALS))
ifneq ($(SYSROOT_ARG_GOALS),)
UBUNTU_BASE_VERSION := $(firstword $(SYSROOT_ARG_GOALS))
endif
endif

UBUNTU_BASE_RELEASE ?= $(shell printf '%s\n' "$(UBUNTU_BASE_VERSION)" | awk -F. '{ if (NF >= 2) print $$1 "." $$2; else print $$0 }')
UBUNTU_BASE_URL ?= https://cdimage.ubuntu.com/ubuntu-base/releases/$(UBUNTU_BASE_RELEASE)/release/ubuntu-base-$(UBUNTU_BASE_VERSION)-base-$(UBUNTU_BASE_ARCH).tar.gz
UBUNTU_BASE_TARBALL ?= $(notdir $(UBUNTU_BASE_URL))

.DEFAULT_GOAL := help

.PHONY: help scripts logs status
.PHONY: configs configs-mod configs-all
.PHONY: kernel kernel-mod kernel-both kernel-all
.PHONY: busybox-static busybox-mipsel-static dropbear-static sftp-static static-tools ensure-static-tools
.PHONY: ubuntu-base setup-sysroot setup-sysroot-ask setup-sysroot-keep export-sysroot initrd sysroot rootfs
.PHONY: grub4dos-framework iso pack-iso
.PHONY: qemu qemu-gui qemu-dry-run
.PHONY: clean clean-static clean-rootfs

POSITIONAL_ARG_GOALS := $(KERNEL_ARG_GOALS) $(SYSROOT_ARG_GOALS)
ifneq ($(POSITIONAL_ARG_GOALS),)
.PHONY: $(POSITIONAL_ARG_GOALS)
$(POSITIONAL_ARG_GOALS):
	@:
endif

define run_logged
	@mkdir -p "$(OUTPUT_DIR)"
	@echo "+ $(1)"
	@$(1) 2>&1 | tee $(2)
endef

help: ## Show available targets
	@awk 'BEGIN { FS = ":.*##"; printf "Usage: make <target> [VAR=value]\n\nTargets:\n" } /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nCommon variables:\n"
	@printf "  KERNEL=%s              Kernel version/input for kernel-* targets\n" "$(KERNEL)"
	@printf "  KERNEL_INPUTS=%s       Raw inputs passed to compile_kernel_outputs.sh\n" "$(KERNEL_INPUTS)"
	@printf "  JOBS=%s                Parallel build jobs\n" "$(JOBS)"
	@printf "  SETUP_FLAGS=%s         Flags for setup_sysroot.sh\n" "$(SETUP_FLAGS)"
	@printf "  QEMU_ARGS=...          Extra args for run_qemu.sh\n"
	@printf "  ISO_ARGS=...           Optional kernel/initrd args for pack-iso\n"
	@printf "  UBUNTU_BASE_VERSION=%s Ubuntu base version for make sysroot\n" "$(UBUNTU_BASE_VERSION)"
	@printf "  UBUNTU_BASE_URL=...    Ubuntu base tarball URL for make sysroot\n"
	@printf "  ISO_KERNEL=%s           Kernel input for make iso\n" "$(ISO_KERNEL)"
	@printf "  ISO_UBUNTU_BASE_VERSION=%s Ubuntu base version for make iso\n" "$(ISO_UBUNTU_BASE_VERSION)"
	@printf "\nExamples:\n"
	@printf "  make kernel 7.0.10\n"
	@printf "  make kernel-mod 7.0.10\n"
	@printf "  make kernel KERNEL=7.0.10\n"
	@printf "  make sysroot\n"
	@printf "  make sysroot 24.04.4\n"
	@printf "  make sysroot SETUP_FLAGS=\"-y --strip-comments\"\n"
	@printf "  make iso\n"

scripts: ## List project scripts
	@find "$(ROOT_DIR)/script" -maxdepth 1 -type f -printf '%f\n' | sort

logs: ## List output log files
	@find "$(OUTPUT_DIR)" -maxdepth 1 -type f -name '*.log' -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort || true

status: ## Show key artifacts and git status
	@printf "Artifacts:\n"
	@ls -lh \
		"$(ROOT_DIR)/busybox" \
		"$(ROOT_DIR)/busybox_aarch64" \
		"$(ROOT_DIR)/busybox_mipsel_mt7621" \
		"$(ROOT_DIR)/busybox_mipsel_mt7621_upx" \
		"$(ROOT_DIR)/dropbearmulti" \
		"$(ROOT_DIR)/dropbearmulti_aarch64" \
		"$(ROOT_DIR)/sftp-server" \
		"$(ROOT_DIR)/sftp-server_aarch64" \
		"$(ROOT_DIR)/build/busybox-static/artifacts/busybox" \
		"$(ROOT_DIR)/build/busybox-static/artifacts/busybox_aarch64" \
		"$(ROOT_DIR)/build/busybox-mipsel-static/artifacts/busybox_mipsel_mt7621" \
		"$(ROOT_DIR)/build/busybox-mipsel-static/artifacts/busybox_mipsel_mt7621_upx" \
		"$(ROOT_DIR)/build/dropbear-static/artifacts/dropbearmulti" \
		"$(ROOT_DIR)/build/dropbear-static/artifacts/dropbearmulti_aarch64" \
		"$(ROOT_DIR)/build/openssh-static/artifacts/sftp-server" \
		"$(ROOT_DIR)/build/openssh-static/artifacts/sftp-server_aarch64" \
		"$(OUTPUT_DIR)"/initrd-*.zst 2>/dev/null || true
	@printf "\nGit status:\n"
	@git status --short

configs: ## Generate standard kernel configs
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/generate_kernel_configs.sh" $(CONFIG_ARGS),"$(OUTPUT_DIR)/generate-configs.log")

configs-mod: ## Generate modular kernel configs
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/generate_kernel_configs_modular.sh" $(CONFIG_ARGS),"$(OUTPUT_DIR)/generate-configs-modular.log")

configs-all: configs configs-mod ## Generate standard and modular configs

kernel: ## Build standard kernel output
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/compile_kernel_outputs.sh" --std $(KERNEL_INPUTS),"$(OUTPUT_DIR)/build-kernel-std.log")

kernel-mod: ## Build modular kernel output
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/compile_kernel_outputs.sh" --mod $(KERNEL_INPUTS),"$(OUTPUT_DIR)/build-kernel-mod.log")

kernel-both: ## Build standard and modular kernel outputs
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/compile_kernel_outputs.sh" --both $(KERNEL_INPUTS),"$(OUTPUT_DIR)/build-kernel-both.log")

kernel-all: ## Build all configured kernel series and flavors
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/compile_kernel_outputs.sh","$(OUTPUT_DIR)/build-kernel-all.log")

busybox-static: ## Build static BusyBox
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/build_static_busybox.sh","$(OUTPUT_DIR)/build-busybox.log")

busybox-mipsel-static: ## Build MT7621/mipsel static BusyBox, UPX copy, and qemu validation
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/build_static_busybox_mipsel.sh","$(OUTPUT_DIR)/build-busybox-mipsel.log")

dropbear-static: ## Build static dropbearmulti
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/build_static_dropbearmulti.sh","$(OUTPUT_DIR)/build-dropbearmulti.log")

sftp-static: ## Build static sftp-server
	$(call run_logged,JOBS=$(JOBS) "$(ROOT_DIR)/script/build_static_sftp_server.sh","$(OUTPUT_DIR)/build-sftp-server.log")

static-tools: ## Build BusyBox, dropbearmulti, and sftp-server
	@$(MAKE) --no-print-directory busybox-static
	@$(MAKE) --no-print-directory dropbear-static
	@$(MAKE) --no-print-directory sftp-static

ensure-static-tools:
	@if [ -f "$(ROOT_DIR)/build/busybox-static/artifacts/busybox" ] || [ -f "$(ROOT_DIR)/busybox" ]; then \
		echo "Using existing busybox artifact"; \
	else \
		$(MAKE) --no-print-directory busybox-static; \
	fi
	@if [ -f "$(ROOT_DIR)/build/dropbear-static/artifacts/dropbearmulti" ] || [ -f "$(ROOT_DIR)/dropbearmulti" ]; then \
		echo "Using existing dropbearmulti artifact"; \
	else \
		$(MAKE) --no-print-directory dropbear-static; \
	fi
	@if [ -f "$(ROOT_DIR)/build/openssh-static/artifacts/sftp-server" ] || [ -f "$(ROOT_DIR)/sftp-server" ]; then \
		echo "Using existing sftp-server artifact"; \
	else \
		$(MAKE) --no-print-directory sftp-static; \
	fi

ubuntu-base: ## Download Ubuntu base tarball for sysroot
	@command -v curl >/dev/null 2>&1 || { echo "error: required command not found: curl" >&2; exit 1; }
	@if [ -f "$(ROOT_DIR)/$(UBUNTU_BASE_TARBALL)" ]; then \
		echo "Using existing $(ROOT_DIR)/$(UBUNTU_BASE_TARBALL)"; \
	else \
		echo "Downloading $(UBUNTU_BASE_URL)"; \
		curl -fL --retry 3 --retry-delay 2 -o "$(ROOT_DIR)/$(UBUNTU_BASE_TARBALL).tmp" "$(UBUNTU_BASE_URL)"; \
		mv "$(ROOT_DIR)/$(UBUNTU_BASE_TARBALL).tmp" "$(ROOT_DIR)/$(UBUNTU_BASE_TARBALL)"; \
		echo "Downloaded $(ROOT_DIR)/$(UBUNTU_BASE_TARBALL)"; \
	fi

setup-sysroot: ## Recreate and configure sysroot; default passes -y
	$(call run_logged,UBUNTU_BASE_TARBALL="$(SETUP_UBUNTU_BASE_TARBALL)" "$(ROOT_DIR)/script/setup_sysroot.sh" $(SETUP_FLAGS),"$(OUTPUT_DIR)/setup-sysroot.log")

setup-sysroot-ask: ## Run setup_sysroot.sh interactively
	$(call run_logged,"$(ROOT_DIR)/script/setup_sysroot.sh","$(OUTPUT_DIR)/setup-sysroot.log")

setup-sysroot-keep: ## Configure existing sysroot without deleting it
	$(call run_logged,"$(ROOT_DIR)/script/setup_sysroot.sh" -n,"$(OUTPUT_DIR)/setup-sysroot.log")

export-sysroot: ## Export sysroot to output/initrd-*.zst
	$(call run_logged,"$(ROOT_DIR)/script/export_sysroot.sh","$(OUTPUT_DIR)/export-sysroot.log")

initrd: export-sysroot ## Alias for export-sysroot

sysroot: ## Download Ubuntu base, ensure static tools, setup, and export initrd
	@$(MAKE) --no-print-directory ubuntu-base \
		UBUNTU_BASE_VERSION="$(UBUNTU_BASE_VERSION)" \
		UBUNTU_BASE_URL="$(UBUNTU_BASE_URL)" \
		UBUNTU_BASE_TARBALL="$(UBUNTU_BASE_TARBALL)"
	@$(MAKE) --no-print-directory ensure-static-tools
	@$(MAKE) --no-print-directory setup-sysroot \
		UBUNTU_BASE_VERSION="$(UBUNTU_BASE_VERSION)" \
		UBUNTU_BASE_URL="$(UBUNTU_BASE_URL)" \
		UBUNTU_BASE_TARBALL="$(UBUNTU_BASE_TARBALL)" \
		SETUP_UBUNTU_BASE_TARBALL="$(UBUNTU_BASE_TARBALL)"
	@$(MAKE) --no-print-directory export-sysroot

rootfs: ## Build static tools, recreate sysroot, and export initrd
	@$(MAKE) --no-print-directory static-tools
	@$(MAKE) --no-print-directory sysroot

grub4dos-framework: ## Build grub4dos legacy and EFI artifacts when missing
	@mkdir -p "$(OUTPUT_DIR)"
	@[ -f "$(ROOT_DIR)/grub4dos/Makefile" ] || { echo "error: grub4dos Makefile not found: $(ROOT_DIR)/grub4dos/Makefile" >&2; exit 1; }
	@if [ -f "$(ROOT_DIR)/grub4dos/artifacts/0.4.6a/grldr" ] && [ -f "$(ROOT_DIR)/grub4dos/artifacts/efi/efisys.bin" ]; then \
		echo "Using existing grub4dos ISO framework artifacts"; \
	else \
		echo "+ make -C $(ROOT_DIR)/grub4dos both"; \
		$(MAKE) -C "$(ROOT_DIR)/grub4dos" both 2>&1 | tee "$(OUTPUT_DIR)/build-grub4dos.log"; \
	fi

iso: ## Build 6.18.x kernel, Ubuntu 26.04 rootfs, grub4dos framework, and final ISO
	@$(MAKE) --no-print-directory kernel KERNEL_INPUTS="$(ISO_KERNEL)"
	@$(MAKE) --no-print-directory sysroot UBUNTU_BASE_VERSION="$(ISO_UBUNTU_BASE_VERSION)"
	@$(MAKE) --no-print-directory grub4dos-framework
	@mkdir -p "$(OUTPUT_DIR)"
	@kernel_path="$(OUTPUT_DIR)/$(ISO_KERNEL_OUTPUT)/bzImage"; \
	initrd_path="$$(find "$(OUTPUT_DIR)" -maxdepth 1 -type f -name 'initrd-*.zst' -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)"; \
	if [ ! -f "$$kernel_path" ]; then \
		echo "error: kernel image not found: $$kernel_path" >&2; \
		exit 1; \
	fi; \
	if [ -z "$$initrd_path" ] || [ ! -f "$$initrd_path" ]; then \
		echo "error: initrd image not found under $(OUTPUT_DIR)" >&2; \
		exit 1; \
	fi; \
	echo "+ $(ROOT_DIR)/script/make_bootable.sh $$kernel_path $$initrd_path"; \
	"$(ROOT_DIR)/script/make_bootable.sh" "$$kernel_path" "$$initrd_path" 2>&1 | tee "$(OUTPUT_DIR)/make-bootable.log"

pack-iso: ## Build bootable ISO from existing kernel/initrd; use ISO_ARGS for overrides
	$(call run_logged,"$(ROOT_DIR)/script/make_bootable.sh" $(ISO_ARGS),"$(OUTPUT_DIR)/make-bootable.log")

qemu: ## Run QEMU with latest kernel/initrd
	@"$(ROOT_DIR)/script/run_qemu.sh" $(QEMU_ARGS)

qemu-gui: ## Run QEMU in GUI mode
	@"$(ROOT_DIR)/script/run_qemu.sh" --gui $(QEMU_ARGS)

qemu-dry-run: ## Print resolved QEMU command
	@"$(ROOT_DIR)/script/run_qemu.sh" --dry-run $(QEMU_ARGS)

clean: ## Remove all generated build artifacts
	@echo "Unmounting sysroot mounts if any"
	@if [ -d "$(ROOT_DIR)/sysroot" ]; then \
		mapfile -t mounts < <(findmnt -rn -o TARGET 2>/dev/null \
			| awk -v sysroot="$(ROOT_DIR)/sysroot" '$$0 == sysroot || index($$0, sysroot "/") == 1 { print }' \
			| awk '{ depth = gsub(/\//, "/"); print depth "\t" $$0 }' \
			| sort -r -n -k1,1 \
			| cut -f2-); \
		for target in "$${mounts[@]}"; do \
			echo "Unmounting $$target"; \
			umount -R "$$target" || umount -Rl "$$target"; \
		done; \
	fi
	@echo "Removing build/, output/, tmp/, sysroot/, rootfs/, and root-level binaries"
	@rm -rf \
		"$(ROOT_DIR)/build" \
		"$(OUTPUT_DIR)" \
		"$(ROOT_DIR)/tmp" \
		"$(ROOT_DIR)/sysroot" \
		"$(ROOT_DIR)/rootfs" \
		"$(ROOT_DIR)/busybox" \
		"$(ROOT_DIR)/busybox_aarch64" \
		"$(ROOT_DIR)/dropbearmulti" \
		"$(ROOT_DIR)/dropbearmulti_aarch64" \
		"$(ROOT_DIR)/sftp-server" \
		"$(ROOT_DIR)/sftp-server_aarch64"
	@rm -rf "$${TMPDIR:-/tmp}"/compile-kernel.*
	@mkdir -p "$(ROOT_DIR)/build" "$(OUTPUT_DIR)"
	@printf '\n' >"$(ROOT_DIR)/build/.gitkeep"
	@printf '\n' >"$(OUTPUT_DIR)/.gitkeep"
	@echo "Cleaned generated artifacts"

clean-static: ## Remove static-tool build trees and root-level static artifacts
	rm -rf \
		"$(ROOT_DIR)/build/busybox-static" \
		"$(ROOT_DIR)/build/dropbear-static" \
		"$(ROOT_DIR)/build/openssh-static" \
		"$(ROOT_DIR)/busybox" \
		"$(ROOT_DIR)/busybox_aarch64" \
		"$(ROOT_DIR)/dropbearmulti" \
		"$(ROOT_DIR)/dropbearmulti_aarch64" \
		"$(ROOT_DIR)/sftp-server" \
		"$(ROOT_DIR)/sftp-server_aarch64"

clean-rootfs: ## Remove rootfs staging directory created by sftp build
	rm -rf "$(ROOT_DIR)/rootfs"
