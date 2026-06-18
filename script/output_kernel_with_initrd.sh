#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained kernel image whose initramfs is a minimal busybox
# rootfs embedded directly into the image (CONFIG_INITRAMFS_SOURCE). The same
# rootfs is also exported as a tar.zst.
#
# The rootfs is described by a gen_init_cpio listing so that ownership (root),
# setuid bits (doas) and device nodes can be expressed without running as root.

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KERNEL_DIR="$ROOT_DIR/kernel"
OUTPUT_DIR="$ROOT_DIR/output"
SOURCE_CACHE_DIR="$ROOT_DIR/tmp/kernel-source-cache"
JOBS=${JOBS:-$(nproc)}
WORK_ROOT=${WORK_ROOT:-"$ROOT_DIR/tmp/kernel-initrd-work"}
INITRD_OUTPUT_DIR=${INITRD_OUTPUT_DIR:-"$OUTPUT_DIR"}

# shellcheck source=/root/kernel/script/kernel_source_matrix.sh
source "$ROOT_DIR/script/kernel_source_matrix.sh"

# --- defaults ---------------------------------------------------------------
ARCH_ALIAS="amd64"                 # amd64 | arm64
KERNEL_SEL="6.18-mod"              # <series>[-mod]
ROOT_PASSWORD="123@@@"
# "boot the NIC as eth0" -> disable predictable interface names.
EXTRA_CMDLINE="net.ifnames=0 biosdevname=0"
# Print kernel messages to both serial and VGA. Keep tty0 last so /dev/console
# is usable in graphical QEMU; /init also starts a separate serial shell.
CONSOLE_CMDLINE=${CONSOLE_CMDLINE:-"console=ttyS0,115200 console=tty0"}
BUILD_KERNEL=1
WORK_DIR=""

usage() {
  cat <<'EOF'
Usage: output_kernel_with_initrd.sh [amd64|arm64] [options]

Builds a kernel image with an embedded busybox initramfs and exports the
rootfs as output/busybox.tar.zst.

Arguments:
  amd64                  Build for x86_64 (default), image -> output/bzImage-busybox
  arm64                  Build for aarch64, image -> output/Image.gz-busybox

Options:
  --kernel <sel>         Kernel config selection (default: 6.18-mod). Examples:
                         6.18-mod, 6.18, 6.6-mod
  --cmdline <args>       Extra built-in kernel cmdline (default: "net.ifnames=0
                         biosdevname=0")
  --no-kernel            Only build the rootfs and busybox.tar.zst, skip the
                         kernel compile
  -h, --help             Show this help

Environment:
  JOBS=<n>               Parallel make jobs (default: nproc)
  WORK_ROOT=<dir>        Large temporary work directory (default:
                         ./tmp/kernel-initrd-work)
  INITRD_OUTPUT_DIR=<dir>
                         Directory for initrd_<arch>.zst and initrd_<arch>.gz
                         (default: ./output)

Embedded users (password == username, except root):
  root / 123@@@   busybox / busybox   bb / bb
All three are in the wheel group; doas grants them passwordless root.
Dropbear (ssh) listens on 22 and 2222 with password auth for these users.
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing required tool: %s\n' "$1" >&2
    exit 1
  }
}

cleanup() {
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}

# --- per-arch asset / toolchain selection -----------------------------------
declare BUSYBOX_BIN SFTP_BIN DROPBEAR_BIN DOAS_BIN
declare KERNEL_ARCH CROSS_COMPILE IMAGE_TARGET IMAGE_REL_PATH OUTPUT_IMAGE_NAME

select_arch_assets() {
  case "$ARCH_ALIAS" in
    amd64|x86_64)
      ARCH_ALIAS="amd64"
      BUSYBOX_BIN="$ROOT_DIR/busybox"
      SFTP_BIN="$ROOT_DIR/sftp-server"
      DROPBEAR_BIN="$ROOT_DIR/dropbearmulti"
      DOAS_BIN="$ROOT_DIR/doas/opendoas-6.8.2/dist/doas-amd64"
      KERNEL_ARCH="x86"
      CROSS_COMPILE=""
      IMAGE_TARGET="bzImage"
      IMAGE_REL_PATH="arch/x86/boot/bzImage"
      OUTPUT_IMAGE_NAME="bzImage-busybox"
      ;;
    arm64|aarch64)
      ARCH_ALIAS="arm64"
      BUSYBOX_BIN="$ROOT_DIR/busybox_aarch64"
      SFTP_BIN="$ROOT_DIR/sftp-server_aarch64"
      DROPBEAR_BIN="$ROOT_DIR/dropbearmulti_aarch64"
      DOAS_BIN="$ROOT_DIR/doas/opendoas-6.8.2/dist/doas-arm64"
      KERNEL_ARCH="arm64"
      CROSS_COMPILE="${AARCH64_CROSS_COMPILE:-aarch64-linux-gnu-}"
      IMAGE_TARGET="Image.gz"
      IMAGE_REL_PATH="arch/arm64/boot/Image.gz"
      OUTPUT_IMAGE_NAME="Image.gz-busybox"
      ;;
    *)
      printf 'error: unknown architecture: %s (use amd64 or arm64)\n' "$ARCH_ALIAS" >&2
      exit 1
      ;;
  esac

  local f
  for f in "$BUSYBOX_BIN" "$SFTP_BIN" "$DROPBEAR_BIN" "$DOAS_BIN"; do
    [[ -f "$f" ]] || {
      printf 'error: required %s binary not found: %s\n' "$ARCH_ALIAS" "$f" >&2
      exit 1
    }
  done
}

# --- rootfs text files ------------------------------------------------------
# All generated into $WORK_DIR/files and referenced from the cpio listing.
write_rootfs_files() {
  local d="$WORK_DIR/files"
  local root_hash busybox_hash bb_hash
  mkdir -p "$d"

  root_hash=$(openssl passwd -6 "$ROOT_PASSWORD")
  busybox_hash=$(openssl passwd -6 "busybox")
  bb_hash=$(openssl passwd -6 "bb")

  # /init -- the kernel's first userspace program.
  cat >"$d/init" <<'INIT'
#!/bin/sh
PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PATH HOME=/root TERM=linux

# Make every busybox applet available as /bin/<applet>.
/bin/busybox --install -s

# Pseudo / virtual filesystems.
mount -t proc     -o nosuid,noexec,nodev proc  /proc 2>/dev/null
mount -t sysfs    -o nosuid,noexec,nodev sysfs /sys  2>/dev/null
mount -t devtmpfs -o nosuid,mode=0755     dev   /dev  2>/dev/null
# tmpfs for /tmp and /run.
mount -t tmpfs -o nosuid,nodev,mode=1777 tmpfs /tmp
mount -t tmpfs -o nosuid,nodev,mode=0755 tmpfs /run
mkdir -p /dev/pts /dev/shm
mount -t devpts -o nosuid,noexec,gid=5,mode=0620 devpts /dev/pts 2>/dev/null
mount -t tmpfs  -o nosuid,nodev,mode=1777 tmpfs  /dev/shm 2>/dev/null

hostname busybox 2>/dev/null

# Networking: bring up loopback + every eth* via busybox udhcpc (ip backend).
ip link set lo up 2>/dev/null
for ifpath in /sys/class/net/eth*; do
    [ -e "$ifpath" ] || continue
    iface=${ifpath##*/}
    ip link set "$iface" up
    udhcpc -i "$iface" -s /usr/share/udhcpc/default.script -t 5 -T 2 -A 2 -b -q \
        >/dev/null 2>&1 || true
done

# Dropbear ssh in the background. Create everything it needs *first* so it
# never fails to start, then detach it.
mkdir -p /etc/dropbear /var/run /var/log /var/empty /run/dropbear /root/.ssh
chmod 0700 /var/empty /root/.ssh
dropbear -R -E -p 22 -p 2222 >/var/log/dropbear.log 2>&1 &

cat <<'BANNER'

  ==> busybox initramfs ready
      console login is root; ssh users: root/123@@@  busybox/busybox  bb/bb
      ssh ports: 22, 2222 (password auth) | doas/sudo: passwordless to root

BANNER

spawn_shell() {
    dev=$1
    name=$2
    [ -e "$dev" ] || return 0

    while true; do
        setsid -c /bin/sh -l <"$dev" >"$dev" 2>&1 || true
        echo "($name shell exited - respawning)" >"$dev" 2>/dev/null || true
        sleep 1
    done
}

# Keep both common QEMU modes interactive:
# - graphical: /dev/console points at tty0 because console=tty0 is last
# - nographic: serial stdio is /dev/ttyS0
spawn_shell /dev/ttyS0 serial &
spawn_shell /dev/console console
INIT

  # busybox udhcpc handler, configured via the ip(8) command.
  cat >"$d/udhcpc.default.script" <<'UDHCPC'
#!/bin/sh
# busybox udhcpc hook using iproute2-style `ip` (provided by busybox).
mask2cidr() {
    local c=0 o
    local IFS=.
    for o in $1; do
        while [ "$o" -gt 0 ]; do c=$((c + (o & 1))); o=$((o >> 1)); done
    done
    echo "$c"
}

case "$1" in
    deconfig)
        ip addr flush dev "$interface" 2>/dev/null
        ip link set "$interface" up
        ;;
    bound|renew)
        prefix=$(mask2cidr "${subnet:-255.255.255.0}")
        ip addr flush dev "$interface" 2>/dev/null
        ip addr add "$ip/$prefix" dev "$interface"
        if [ -n "$router" ]; then
            ip route del default 2>/dev/null
            for r in $router; do
                ip route add default via "$r" dev "$interface" && break
            done
        fi
        if [ -n "$dns" ]; then
            : > /etc/resolv.conf
            for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
        fi
        ;;
esac
UDHCPC

  # sudo -> doas shim. Only `sudo <cmd>` and `sudo -s` are handled; anything
  # else is rejected with a hint.
  cat >"$d/sudo" <<'SUDO'
#!/bin/sh
# Minimal sudo wrapper that forwards to doas.
if [ "$#" -eq 0 ]; then
    echo "用法: sudo <命令>   或   sudo -s" >&2
    exit 1
fi
case "$1" in
    -s)
        shift
        exec doas -s "$@"
        ;;
    -*)
        echo "sudo: 不支持的参数 '$1';仅支持 'sudo <命令>'。" \
             "其它用法请使用 'sudo -s' 或 'doas' 执行。" >&2
        exit 1
        ;;
    *)
        exec doas "$@"
        ;;
esac
SUDO

  # doas: passwordless root for the wheel group (covers every account that logs
  # in through dropbear/login, which run initgroups). The explicit root rule
  # also covers the PID 1 console shell, which has no supplementary groups.
  cat >"$d/doas.conf" <<'DOASCONF'
permit nopass keepenv :wheel
permit nopass keepenv root
DOASCONF

  cat >"$d/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
busybox:x:1000:1000:busybox:/home/busybox:/bin/sh
bb:x:1001:1001:bb:/home/bb:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
EOF

  cat >"$d/group" <<'EOF'
root:x:0:
tty:x:5:
wheel:x:10:root,busybox,bb
nogroup:x:65534:
busybox:x:1000:
bb:x:1001:
EOF

  cat >"$d/shadow" <<EOF
root:${root_hash}:19000:0:99999:7:::
busybox:${busybox_hash}:19000:0:99999:7:::
bb:${bb_hash}:19000:0:99999:7:::
nobody:!:19000:0:99999:7:::
EOF

  printf '/bin/sh\n/bin/ash\n' >"$d/shells"
  printf 'busybox\n' >"$d/hostname"

  cat >"$d/profile" <<'EOF'
export PATH=/sbin:/usr/sbin:/bin:/usr/bin
export PAGER=more
alias ll='ls -la'
PS1='\u@\h:\w\$ '
EOF

  cat >"$d/services" <<'EOF'
ftp-data	20/tcp
ftp		21/tcp
ssh		22/tcp
http		80/tcp		www www-http
https		443/tcp
ftps		990/tcp
EOF
}

# --- gen_init_cpio listing --------------------------------------------------
emit_listing() {
  local f="$WORK_DIR/files"
  cat <<EOF
# directories
dir /bin 0755 0 0
dir /sbin 0755 0 0
dir /usr 0755 0 0
dir /usr/bin 0755 0 0
dir /usr/sbin 0755 0 0
dir /usr/lib 0755 0 0
dir /usr/lib/openssh 0755 0 0
dir /usr/libexec 0755 0 0
dir /usr/share 0755 0 0
dir /usr/share/udhcpc 0755 0 0
dir /etc 0755 0 0
dir /etc/dropbear 0755 0 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /dev 0755 0 0
dir /dev/pts 0755 0 0
dir /tmp 1777 0 0
dir /run 0755 0 0
dir /var 0755 0 0
dir /var/run 0755 0 0
dir /var/log 0755 0 0
dir /var/empty 0700 0 0
dir /root 0700 0 0
dir /home 0755 0 0
dir /home/busybox 0755 1000 1000
dir /home/bb 0755 1001 1001

# busybox + shells
file /bin/busybox $BUSYBOX_BIN 0755 0 0
slink /bin/sh busybox 0777 0 0
file /init $f/init 0755 0 0

# dropbear (multi-call binary) + sftp-server in dropbear's default locations
file /usr/sbin/dropbear $DROPBEAR_BIN 0755 0 0
slink /usr/bin/dropbearkey /usr/sbin/dropbear 0777 0 0
slink /usr/bin/dropbearconvert /usr/sbin/dropbear 0777 0 0
file /usr/libexec/sftp-server $SFTP_BIN 0755 0 0
slink /usr/lib/openssh/sftp-server /usr/libexec/sftp-server 0777 0 0
slink /usr/lib/sftp-server /usr/libexec/sftp-server 0777 0 0

# doas (setuid root) + sudo shim
file /usr/bin/doas $DOAS_BIN 4755 0 0
file /usr/bin/sudo $f/sudo 0755 0 0
file /etc/doas.conf $f/doas.conf 0644 0 0

# accounts
file /etc/passwd $f/passwd 0644 0 0
file /etc/group $f/group 0644 0 0
file /etc/shadow $f/shadow 0600 0 0
file /etc/shells $f/shells 0644 0 0
file /etc/hostname $f/hostname 0644 0 0
file /etc/profile $f/profile 0644 0 0
file /etc/services $f/services 0644 0 0

# networking
file /usr/share/udhcpc/default.script $f/udhcpc.default.script 0755 0 0

# device nodes (init remounts devtmpfs over /dev for the full set)
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/zero 0666 0 0 c 1 5
nod /dev/full 0666 0 0 c 1 7
nod /dev/random 0666 0 0 c 1 8
nod /dev/urandom 0666 0 0 c 1 9
nod /dev/tty 0666 0 0 c 5 0
nod /dev/ttyS0 0660 0 0 c 4 64
nod /dev/ptmx 0666 0 0 c 5 2
EOF
}

build_gen_init_cpio() {
  local src_dir=$1
  local out=$2
  gcc -O2 -o "$out" "$src_dir/usr/gen_init_cpio.c"
}

# --- kernel source ----------------------------------------------------------
ensure_kernel_source() {
  local series=$1
  local cached full_version url dest

  cached=$(ls "$SOURCE_CACHE_DIR"/linux-"${series}".*.tar.xz 2>/dev/null | sort -V | tail -n1 || true)
  if [[ -z "$cached" ]]; then
    full_version=$(kernel_full_version_for_series "$series") || {
      printf 'error: cannot resolve a version for series %s\n' "$series" >&2
      exit 1
    }
    cached="$SOURCE_CACHE_DIR/$(kernel_tarball_name_for_version "$full_version")"
    url=$(kernel_tarball_url_for_version "$full_version")
    mkdir -p "$SOURCE_CACHE_DIR"
    printf '==> Downloading %s\n' "$url" >&2
    curl -fL --retry 3 --retry-delay 2 -o "$cached" "$url"
  fi

  dest="$WORK_DIR/src"
  mkdir -p "$dest"
  printf '==> Extracting %s\n' "$(basename "$cached")" >&2
  tar -xf "$cached" -C "$dest"
  find "$dest" -mindepth 1 -maxdepth 1 -type d -name 'linux-*' | head -n1
}

# --- main -------------------------------------------------------------------
main() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      amd64|x86_64|arm64|aarch64) ARCH_ALIAS=$1 ;;
      --kernel) KERNEL_SEL=${2:?--kernel requires a value}; shift ;;
      --kernel=*) KERNEL_SEL=${1#*=} ;;
      --cmdline) EXTRA_CMDLINE=${2:?--cmdline requires a value}; shift ;;
      --cmdline=*) EXTRA_CMDLINE=${1#*=} ;;
      --no-kernel) BUILD_KERNEL=0 ;;
      -h|--help) usage; return 0 ;;
      *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
  done

  require_tool openssl
  require_tool gcc
  require_tool tar
  require_tool zstd
  require_tool bsdtar
  require_tool find
  [[ "$BUILD_KERNEL" -eq 1 ]] && { require_tool make; require_tool curl; }

  select_arch_assets

  # config selection: <series>[-mod]
  local config_suffix="" series=$KERNEL_SEL
  case "$KERNEL_SEL" in
    *-mod|*-modular) config_suffix="-modular"; series=${KERNEL_SEL%-mod}; series=${series%-modular} ;;
  esac
  local config_path="$KERNEL_DIR/linux-${series}${config_suffix}.config"
  [[ -f "$config_path" ]] || {
    printf 'error: kernel config not found: %s\n' "$config_path" >&2
    exit 1
  }

  if [[ "$ARCH_ALIAS" == "arm64" ]]; then
    [[ "$BUILD_KERNEL" -eq 0 ]] || require_tool "${CROSS_COMPILE}gcc"
  fi

  trap cleanup EXIT
  mkdir -p "$WORK_ROOT"
  WORK_DIR=$(mktemp -d "$WORK_ROOT/kernel-initrd.XXXXXX")
  mkdir -p "$WORK_DIR/tmp"
  export TMPDIR="$WORK_DIR/tmp"
  mkdir -p "$OUTPUT_DIR" "$INITRD_OUTPUT_DIR"

  echo "==> Architecture : $ARCH_ALIAS"
  echo "==> Kernel config: $config_path"
  echo "==> Work dir     : $WORK_DIR"
  echo "==> Building rootfs files"
  write_rootfs_files

  local listing="$WORK_DIR/initramfs.list"
  emit_listing >"$listing"
  echo "==> Wrote cpio listing: $listing"

  # Need a kernel source tree both for gen_init_cpio and (optionally) the build.
  local src_dir
  src_dir=$(ensure_kernel_source "$series")
  [[ -n "$src_dir" && -d "$src_dir" ]] || {
    printf 'error: could not locate extracted kernel source\n' >&2
    exit 1
  }

  # Export a bootable initramfs (cpio -> zstd/gzip) plus a tar.zst rootfs.
  local initrd_zst="$INITRD_OUTPUT_DIR/initrd_${ARCH_ALIAS}.zst"
  local initrd_gz="$INITRD_OUTPUT_DIR/initrd_${ARCH_ALIAS}.gz"
  echo "==> Exporting initrd to $initrd_zst and $initrd_gz"
  build_gen_init_cpio "$src_dir" "$WORK_DIR/gen_init_cpio"
  "$WORK_DIR/gen_init_cpio" "$listing" >"$WORK_DIR/initramfs.cpio"
  zstd -19 --long -T0 -f -q -o "$WORK_DIR/initrd_${ARCH_ALIAS}.zst" "$WORK_DIR/initramfs.cpio"
  gzip -n -9 -c "$WORK_DIR/initramfs.cpio" >"$WORK_DIR/initrd_${ARCH_ALIAS}.gz"
  mv "$WORK_DIR/initrd_${ARCH_ALIAS}.zst" "$initrd_zst"
  mv "$WORK_DIR/initrd_${ARCH_ALIAS}.gz" "$initrd_gz"
  ls -lh "$initrd_zst" "$initrd_gz"

  echo "==> Exporting rootfs to $OUTPUT_DIR/busybox.tar.zst"
  bsdtar --format gnutar -cf "$WORK_DIR/busybox.tar" "@$WORK_DIR/initramfs.cpio"
  zstd -19 --long -T0 -f -q -o "$OUTPUT_DIR/busybox.tar.zst" "$WORK_DIR/busybox.tar"
  ls -lh "$OUTPUT_DIR/busybox.tar.zst"

  if [[ "$BUILD_KERNEL" -eq 0 ]]; then
    echo "==> --no-kernel set; skipping kernel build"
    return 0
  fi

  # Configure + build the kernel with the initramfs and cmdline baked in.
  local build_dir="$WORK_DIR/build"
  local cmdline="$CONSOLE_CMDLINE $EXTRA_CMDLINE"
  mkdir -p "$build_dir"
  cp "$config_path" "$build_dir/.config"

  "$src_dir/scripts/config" --file "$build_dir/.config" \
    --enable BLK_DEV_INITRD \
    --set-str INITRAMFS_SOURCE "$listing" \
    --enable CMDLINE_BOOL \
    --set-str CMDLINE "$cmdline"

  local -a make_vars=("ARCH=$KERNEL_ARCH")
  [[ -n "$CROSS_COMPILE" ]] && make_vars+=("CROSS_COMPILE=$CROSS_COMPILE")

  echo "==> Configuring kernel (cmdline: $cmdline)"
  make -C "$src_dir" O="$build_dir" "${make_vars[@]}" olddefconfig

  echo "==> Building $IMAGE_TARGET (-j$JOBS)"
  make -C "$src_dir" O="$build_dir" "${make_vars[@]}" -j"$JOBS" "$IMAGE_TARGET"

  cp "$build_dir/$IMAGE_REL_PATH" "$OUTPUT_DIR/$OUTPUT_IMAGE_NAME"
  echo "==> Done"
  ls -lh "$OUTPUT_DIR/$OUTPUT_IMAGE_NAME" "$OUTPUT_DIR/busybox.tar.zst"
}

main "$@"
