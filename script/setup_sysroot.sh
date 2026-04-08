#!/usr/bin/env bash

set -euo pipefail

echo "Setting up sysroot for initramfs"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSROOT_DIR="$ROOT_DIR/sysroot"
ETC_DIR="$SYSROOT_DIR/etc"
APT_PACKAGES=(systemd dbus)
CHROOT_ENV=(env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8)
DROPBEAR_USR_BIN_APPLETS=(dbclient ssh dropbearkey ssh-keygen dropbearconvert scp)
ROOT_PASSWORD='123@@@'
DEFAULT_USER=ubuntu
DEFAULT_USER_PASSWORD=ubuntu
RESET_SYSROOT_MODE=ask

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 [-y|-n]" >&2
  exit 1
}

mount_if_needed() {
  local source=$1
  local target=$2
  shift 2

  mkdir -p "$target"
  if mountpoint -q "$target"; then
    echo "Mount already present: $target"
    return
  fi

  mount "$@" "$source" "$target"
  echo "Mounted $target"
}

find_artifact() {
  local name=$1
  shift
  local path

  if [ -d "$ROOT_DIR/output" ]; then
    path="$(find "$ROOT_DIR/output" -type f -name "$name" -print -quit 2>/dev/null || true)"
    if [ -n "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi

  for path in "$@"; do
    if [ -f "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  return 1
}

install_executable() {
  local source=$1
  local target=$2

  install -Dm755 "$source" "$target"
  echo "Installed $target"
}

cleanup_dir_contents() {
  local dir=$1

  mkdir -p "$dir"
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  echo "Cleaned $dir"
}

umount_if_mounted() {
  local target=$1

  if ! mountpoint -q "$target"; then
    echo "Mount not present: $target"
    return
  fi

  if umount -R "$target"; then
    echo "Unmounted $target"
    return
  fi

  umount -Rl "$target"
  echo "Lazily unmounted $target"
}

get_sysroot_mount_targets() {
  findmnt -rn -o TARGET 2>/dev/null \
    | awk -v sysroot="$SYSROOT_DIR" '
        $0 == sysroot || index($0, sysroot "/") == 1 {
          print
        }
      '
}

sort_mount_targets_by_depth_desc() {
  awk '
    {
      depth = gsub(/\//, "/")
      print depth "\t" $0
    }
  ' | sort -r -n -k1,1 | cut -f2-
}

unmount_all_sysroot_mounts() {
  local -a mount_targets=()
  local target

  if [ ! -d "$SYSROOT_DIR" ]; then
    return
  fi

  mapfile -t mount_targets < <(get_sysroot_mount_targets)

  if [ "${#mount_targets[@]}" -eq 0 ]; then
    echo "No active mounts found under $SYSROOT_DIR"
    return
  fi

  echo "Unmounting active mounts under $SYSROOT_DIR"
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    umount_if_mounted "$target"
  done < <(printf '%s\n' "${mount_targets[@]}" | sort_mount_targets_by_depth_desc)
}

find_latest_ubuntu_base() {
  local latest

  latest="$(
    find "$ROOT_DIR" -maxdepth 1 -type f \
      \( -name 'ubuntu-base*.tar.gz' -o -name 'ubuntu-base*.tar.xz' -o -name 'ubuntu-base*.tar.zst' \) \
      -printf '%T@ %p\n' \
      | sort -n \
      | tail -n 1 \
      | cut -d' ' -f2-
  )"

  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

extract_ubuntu_base() {
  local tarball=$1

  mkdir -p "$SYSROOT_DIR"
  tar -xf "$tarball" -C "$SYSROOT_DIR"
  echo "Extracted $(basename "$tarball") into $SYSROOT_DIR"
}

prepare_base_sysroot() {
  local answer tarball

  if [ -d "$SYSROOT_DIR" ]; then
    case "$RESET_SYSROOT_MODE" in
      yes)
        answer=y
        ;;
      no)
        answer=n
        ;;
      ask)
        printf 'Delete existing sysroot/ first? [y/N] '
        read -r answer || answer=n
        ;;
      *)
        die "invalid reset mode: $RESET_SYSROOT_MODE"
        ;;
    esac
    case "$answer" in
      y|Y)
        unmount_all_sysroot_mounts
        rm -rf "$SYSROOT_DIR"
        mkdir -p "$SYSROOT_DIR"
        tarball="$(find_latest_ubuntu_base)" || die "latest ubuntu-base tarball not found in $ROOT_DIR"
        extract_ubuntu_base "$tarball"
        ;;
      *)
        echo "Keeping existing $SYSROOT_DIR"
        ;;
    esac
    return
  fi

  mkdir -p "$SYSROOT_DIR"
  tarball="$(find_latest_ubuntu_base)" || die "latest ubuntu-base tarball not found in $ROOT_DIR"
  extract_ubuntu_base "$tarball"
}

while getopts ':yn' opt; do
  case "$opt" in
    y)
      [ "$RESET_SYSROOT_MODE" = ask ] || usage
      RESET_SYSROOT_MODE=yes
      ;;
    n)
      [ "$RESET_SYSROOT_MODE" = ask ] || usage
      RESET_SYSROOT_MODE=no
      ;;
    *)
      usage
      ;;
  esac
done

shift $((OPTIND - 1))
[ "$#" -eq 0 ] || usage

prepare_base_sysroot

mkdir -p "$ETC_DIR"
mkdir -p "$ETC_DIR/dropbear"
chmod 700 "$ETC_DIR/dropbear"

mkdir -p "$SYSROOT_DIR/var" "$SYSROOT_DIR/run"
if [ ! -e "$SYSROOT_DIR/var/run" ]; then
  ln -s /run "$SYSROOT_DIR/var/run"
  echo "Linked $SYSROOT_DIR/var/run -> /run"
fi

cat >"$ETC_DIR/resolv.conf" <<'EOF'
nameserver 1.1.1.1
EOF

cat >"$ETC_DIR/hostname" <<'EOF'
localhost
EOF

cat >"$ETC_DIR/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 localhost
::1 localhost ip6-localhost ip6-loopback
EOF

: >"$ETC_DIR/motd"
: >"$ETC_DIR/legal"

cat >"$ETC_DIR/issue" <<EOF
Ubuntu 24.04.4 LTS \n \l

Accounts:
  root / ${ROOT_PASSWORD}
  ${DEFAULT_USER} / ${DEFAULT_USER_PASSWORD}
EOF

cat >"$SYSROOT_DIR/mirror.sh" <<'EOF'
#!/bin/sh

set -eu

SOURCES_FILE=/etc/apt/sources.list.d/ubuntu.sources
RESOLV_FILE=/etc/resolv.conf

usage() {
  echo "Usage: /mirror.sh cn|os" >&2
  exit 1
}

[ $# -eq 1 ] || usage
[ -f "$SOURCES_FILE" ] || {
  echo "Missing $SOURCES_FILE" >&2
  exit 1
}

case "$1" in
  cn)
    cat >"$SOURCES_FILE" <<'EOCN'
Types: deb
URIs: http://mirrors4.tuna.tsinghua.edu.cn/ubuntu
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://mirrors4.tuna.tsinghua.edu.cn/ubuntu
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOCN
    cat >"$RESOLV_FILE" <<'EODNS'
nameserver 119.29.29.29
nameserver 223.5.5.5
EODNS
    ;;
  os)
    cat >"$SOURCES_FILE" <<'EOOS'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOOS
    cat >"$RESOLV_FILE" <<'EODNS'
nameserver 1.1.1.1
nameserver 8.8.8.8
EODNS
    ;;
  *)
    usage
    ;;
esac

echo "Updated $SOURCES_FILE with mode: $1"
EOF

chmod 755 "$SYSROOT_DIR/mirror.sh"
install -Dm755 "$ROOT_DIR/script/init" "$SYSROOT_DIR/init"
install -Dm755 "$ROOT_DIR/script/udhcpc.default.script" "$SYSROOT_DIR/usr/share/udhcpc/default.script"

echo "Configured $ETC_DIR/resolv.conf"
echo "Configured $ETC_DIR/hostname"
echo "Configured $ETC_DIR/hosts"
echo "Configured empty $ETC_DIR/motd"
echo "Configured empty $ETC_DIR/legal"
echo "Configured $ETC_DIR/issue"
echo "Configured $SYSROOT_DIR/mirror.sh"
echo "Configured $SYSROOT_DIR/init"
echo "Configured $SYSROOT_DIR/usr/share/udhcpc/default.script"
echo "Prepared $ETC_DIR/dropbear for auto-generated host keys"

mkdir -p \
  "$SYSROOT_DIR/proc" \
  "$SYSROOT_DIR/sys" \
  "$SYSROOT_DIR/dev" \
  "$SYSROOT_DIR/run"

mount_if_needed proc "$SYSROOT_DIR/proc" -t proc
mount_if_needed /sys "$SYSROOT_DIR/sys" --rbind
mount_if_needed /dev "$SYSROOT_DIR/dev" --rbind
mount_if_needed /run "$SYSROOT_DIR/run" --rbind

mount --make-rslave "$SYSROOT_DIR/sys" || true
mount --make-rslave "$SYSROOT_DIR/dev" || true
mount --make-rslave "$SYSROOT_DIR/run" || true

echo "Running apt-get update inside chroot"
chroot "$SYSROOT_DIR" "${CHROOT_ENV[@]}" apt-get update

echo "Installing packages inside chroot: ${APT_PACKAGES[*]}"
chroot "$SYSROOT_DIR" "${CHROOT_ENV[@]}" apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"

if [ -d "$SYSROOT_DIR/etc/update-motd.d" ]; then
  rm -f \
    "$SYSROOT_DIR/etc/update-motd.d/10-help-text" \
    "$SYSROOT_DIR/etc/update-motd.d/50-motd-news" \
    "$SYSROOT_DIR/etc/update-motd.d/60-unminimize"
  echo "Removed verbose MOTD scripts"
fi

mkdir -p "$SYSROOT_DIR/etc/update-motd.d"
cat >"$SYSROOT_DIR/etc/update-motd.d/99-access-info" <<EOF
#!/bin/sh

bb=/usr/bin/busybox
root_password='${ROOT_PASSWORD}'
default_user='${DEFAULT_USER}'
default_user_password='${DEFAULT_USER_PASSWORD}'

get_ipv4_list() {
  [ -x "\$bb" ] || return 0
  "\$bb" ip -4 -o addr show 2>/dev/null \
    | awk '\$2 != "lo" && \$4 != "" { split(\$4, a, "/"); print \$2 " " a[1] }'
}

get_example_iface() {
  local_iface="\$(
    [ -x "\$bb" ] && "\$bb" ip -o link show 2>/dev/null \
      | awk -F': ' '\$2 != "lo" { gsub(/@.*/, "", \$2); print \$2; exit }'
  )"
  [ -n "\$local_iface" ] || local_iface=eth0
  printf '%s\n' "\$local_iface"
}

echo
echo " * Access:"
printf '   root / %s\n' "\$root_password"
printf '   %s / %s\n' "\$default_user" "\$default_user_password"

ip_list="\$(get_ipv4_list)"
if [ -n "\$ip_list" ]; then
  echo " * SSH:"
  echo "\$ip_list" | while read -r iface ip; do
    [ -n "\$iface" ] || continue
    printf '   %s: ssh %s@%s or ssh root@%s\n' "\$iface" "\$default_user" "\$ip" "\$ip"
  done
else
  iface="\$(get_example_iface)"
  echo " * SSH:"
  echo "   No IPv4 address detected yet."
  echo "   Example BusyBox network setup:"
  printf '   busybox ip link set %s up\n' "\$iface"
  printf '   busybox ip addr add 192.168.1.100/24 dev %s\n' "\$iface"
  printf '   busybox ip route add default via 192.168.1.1 dev %s\n' "\$iface"
fi
EOF
chmod 755 "$SYSROOT_DIR/etc/update-motd.d/99-access-info"
echo "Configured $SYSROOT_DIR/etc/update-motd.d/99-access-info"

if ! chroot "$SYSROOT_DIR" /usr/bin/getent passwd "$DEFAULT_USER" >/dev/null 2>&1; then
  chroot "$SYSROOT_DIR" "${CHROOT_ENV[@]}" /usr/sbin/useradd -m -s /bin/bash "$DEFAULT_USER"
  echo "Created user $DEFAULT_USER"
fi

printf '%s:%s\n' "$DEFAULT_USER" "$DEFAULT_USER_PASSWORD" | chroot "$SYSROOT_DIR" "${CHROOT_ENV[@]}" /usr/sbin/chpasswd
echo "Configured password for $DEFAULT_USER"

printf 'root:%s\n' "$ROOT_PASSWORD" | chroot "$SYSROOT_DIR" "${CHROOT_ENV[@]}" /usr/sbin/chpasswd
echo "Configured root password"

rm -rf \
  "$SYSROOT_DIR/etc/systemd/system/serial-getty@.service.d" \
  "$SYSROOT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d"
mkdir -p "$SYSROOT_DIR/etc/systemd/system/getty@tty1.service.d"
cat >"$SYSROOT_DIR/etc/systemd/system/getty@tty1.service.d/autologin-root.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
TTYVTDisallocate=no
EOF
echo "Configured getty@tty1 root autologin override"

BUSYBOX_SRC="$(
  find_artifact busybox \
    "$ROOT_DIR/build/busybox-static/artifacts/busybox" \
    "$ROOT_DIR/busybox"
)" || die "busybox artifact not found in output/ or build artifacts"

DROPBEARMULTI_SRC="$(
  find_artifact dropbearmulti \
    "$ROOT_DIR/build/dropbear-static/artifacts/dropbearmulti" \
    "$ROOT_DIR/dropbearmulti"
)" || die "dropbearmulti artifact not found in output/ or build artifacts"

SFTPSERVER_SRC="$(
  find_artifact sftp-server \
    "$ROOT_DIR/build/openssh-static/artifacts/sftp-server" \
    "$ROOT_DIR/sftp-server"
)" || die "sftp-server artifact not found in output/ or build artifacts"

install_executable "$BUSYBOX_SRC" "$SYSROOT_DIR/usr/bin/busybox"
install_executable "$DROPBEARMULTI_SRC" "$SYSROOT_DIR/usr/sbin/dropbearmulti"
install_executable "$SFTPSERVER_SRC" "$SYSROOT_DIR/usr/libexec/sftp-server"

chroot "$SYSROOT_DIR" /bin/sh -lc 'cd / && /usr/bin/busybox --install -s'
echo "Installed BusyBox applet symlinks"

mkdir -p "$SYSROOT_DIR/usr/lib/openssh"
ln -sfn ../../libexec/sftp-server "$SYSROOT_DIR/usr/lib/openssh/sftp-server"
echo "Linked $SYSROOT_DIR/usr/lib/openssh/sftp-server -> ../../libexec/sftp-server"

ln -sfn /lib/systemd/systemd "$SYSROOT_DIR/sbin/init"
echo "Linked $SYSROOT_DIR/sbin/init -> /lib/systemd/systemd"

ln -sfn dropbearmulti "$SYSROOT_DIR/usr/sbin/dropbear"
echo "Linked $SYSROOT_DIR/usr/sbin/dropbear -> dropbearmulti"

for applet in "${DROPBEAR_USR_BIN_APPLETS[@]}"; do
  ln -sfn ../sbin/dropbearmulti "$SYSROOT_DIR/usr/bin/$applet"
  echo "Linked $SYSROOT_DIR/usr/bin/$applet -> ../sbin/dropbearmulti"
done

echo "Cleaning package caches and logs"
chroot "$SYSROOT_DIR" "${CHROOT_ENV[@]}" apt-get clean

cleanup_dir_contents "$SYSROOT_DIR/var/log"
cleanup_dir_contents "$SYSROOT_DIR/var/cache"
cleanup_dir_contents "$SYSROOT_DIR/var/lib/apt/lists"
cleanup_dir_contents "$SYSROOT_DIR/var/lib/apt/archives"
cleanup_dir_contents "$SYSROOT_DIR/var/lib/systemd/coredump"
cleanup_dir_contents "$SYSROOT_DIR/var/crash"
cleanup_dir_contents "$SYSROOT_DIR/tmp"
cleanup_dir_contents "$SYSROOT_DIR/var/tmp"
cleanup_dir_contents "$SYSROOT_DIR/root/.cache"

rm -f "$SYSROOT_DIR/root/.bash_history"
echo "Removed $SYSROOT_DIR/root/.bash_history"

echo "Unmounting sysroot bind mounts"
umount_if_mounted "$SYSROOT_DIR/run"
umount_if_mounted "$SYSROOT_DIR/dev"
umount_if_mounted "$SYSROOT_DIR/sys"
umount_if_mounted "$SYSROOT_DIR/proc"
