#!/usr/bin/env bash

set -euo pipefail

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
STRIP_SYSROOT_COMMENTS=no
UBUNTU_BASE_TARBALL="${UBUNTU_BASE_TARBALL:-}"
REINSTALL_SCRIPT_URL="${REINSTALL_SCRIPT_URL:-https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<EOF
Usage: $0 [-y|-n] [--strip-comments]

Options:
  -y, --yes             Delete existing sysroot/ without prompting
  -n, --no              Keep existing sysroot/ and configure it in place
      --strip-comments  Remove comments from shell scripts and config files in sysroot/
  -h, --help            Show this help
EOF
  exit "${1:-1}"
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

is_text_file() {
  local file_path=$1

  [ ! -s "$file_path" ] || LC_ALL=C grep -Iq . "$file_path"
}

has_shell_shebang() {
  local file_path=$1
  local first_line

  IFS= read -r first_line <"$file_path" || return 1
  case "$first_line" in
    '#!'*'/sh'*|'#!'*'/bash'*|'#!'*'/dash'*|'#!'*'/ksh'*|'#!'*'/zsh'*|'#!'*'env sh'*|'#!'*'env bash'*|'#!'*'env dash'*)
      return 0
      ;;
  esac

  return 1
}

is_shell_script_path() {
  local file_path=$1
  local rel_path=${file_path#"$SYSROOT_DIR"/}
  local base_name=${file_path##*/}

  case "$base_name" in
    *.sh|*.bash|*.bashrc|.bash_profile|.bash_login|.bash_logout|.profile|profile)
      return 0
      ;;
  esac

  case "$rel_path" in
    etc/init.d/*|etc/cron.*/*|etc/profile.d/*|etc/update-motd.d/*|usr/lib/*/profile.d/*|usr/share/dpkg/sh/*)
      return 0
      ;;
  esac

  return 1
}

is_config_path() {
  local file_path=$1
  local rel_path=${file_path#"$SYSROOT_DIR"/}
  local base_name=${file_path##*/}

  case "$rel_path" in
    etc/*|usr/lib/systemd/*|usr/lib/sysctl.d/*|usr/lib/modprobe.d/*|usr/lib/sysusers.d/*|usr/lib/tmpfiles.d/*|usr/lib/udev/rules.d/*|usr/share/dbus-1/*|usr/share/factory/etc/*)
      return 0
      ;;
  esac

  case "$base_name" in
    *.conf|*.cfg|*.cnf|*.ini|*.list|*.sources|*.service|*.socket|*.target|*.timer|*.mount|*.path|*.slice|*.automount|*.rules)
      return 0
      ;;
  esac

  return 1
}

copy_file_metadata() {
  local source=$1
  local target=$2

  chmod --reference="$source" "$target" 2>/dev/null || true
  chown --reference="$source" "$target" 2>/dev/null || true
  touch -r "$source" "$target" 2>/dev/null || true
}

rewrite_file_if_changed() {
  local file_path=$1
  local tmp_path=$2

  copy_file_metadata "$file_path" "$tmp_path"
  if cmp -s "$file_path" "$tmp_path"; then
    rm -f "$tmp_path"
    return 1
  fi

  mv -f "$tmp_path" "$file_path"
  return 0
}

strip_shell_comments() {
  local file_path=$1
  local tmp_path

  is_text_file "$file_path" || return 1
  tmp_path="$(mktemp "$(dirname "$file_path")/.${file_path##*/}.strip-comments.XXXXXX")" || return 2

  if ! awk '
    BEGIN {
      squote = sprintf("%c", 39)
      heredoc_count = 0
    }

    function previous_starts_comment(prev) {
      return prev == "" || prev ~ /[[:space:]]/ || prev ~ /[;&|()<>]/
    }

    function strip_hash_comment(line,    i, c, prev, prefix, quote, escaped) {
      quote = ""
      escaped = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)

        if (escaped) {
          escaped = 0
          continue
        }

        if (quote == squote) {
          if (c == squote) {
            quote = ""
          }
          continue
        }

        if (quote == "\"") {
          if (c == "\\") {
            escaped = 1
            continue
          }
          if (c == "\"") {
            quote = ""
          }
          continue
        }

        if (c == "\\") {
          escaped = 1
          continue
        }
        if (c == squote) {
          quote = squote
          continue
        }
        if (c == "\"") {
          quote = "\""
          continue
        }
        if (c == "#") {
          prev = i == 1 ? "" : substr(line, i - 1, 1)
          if (previous_starts_comment(prev)) {
            prefix = substr(line, 1, i - 1)
            sub(/[[:space:]]+$/, "", prefix)
            return prefix
          }
        }
      }
      return line
    }

    function queue_heredocs(line,    rest, q, endq, delim) {
      rest = line
      while (match(rest, /<<-?[[:space:]]*/)) {
        rest = substr(rest, RSTART + RLENGTH)
        q = substr(rest, 1, 1)

        if (q == squote || q == "\"") {
          rest = substr(rest, 2)
          endq = index(rest, q)
          if (!endq) {
            break
          }
          delim = substr(rest, 1, endq - 1)
          rest = substr(rest, endq + 1)
        } else {
          if (q == "\\") {
            rest = substr(rest, 2)
          }
          if (!match(rest, /^[A-Za-z0-9_.:-]+/)) {
            break
          }
          delim = substr(rest, RSTART, RLENGTH)
          rest = substr(rest, RLENGTH + 1)
        }

        if (delim != "") {
          heredocs[++heredoc_count] = delim
        }
      }
    }

    function shift_heredocs(    i) {
      for (i = 1; i < heredoc_count; i++) {
        heredocs[i] = heredocs[i + 1]
      }
      delete heredocs[heredoc_count]
      heredoc_count--
    }

    NR == 1 && /^#!/ {
      print
      next
    }

    heredoc_count > 0 {
      print
      marker = $0
      sub(/^\t+/, "", marker)
      if (marker == heredocs[1]) {
        shift_heredocs()
      }
      next
    }

    {
      stripped = strip_hash_comment($0)
      if (stripped != "") {
        print stripped
        queue_heredocs(stripped)
      }
    }
  ' "$file_path" >"$tmp_path"; then
    rm -f "$tmp_path"
    return 2
  fi

  rewrite_file_if_changed "$file_path" "$tmp_path"
}

strip_config_comments() {
  local file_path=$1
  local tmp_path

  is_text_file "$file_path" || return 1
  tmp_path="$(mktemp "$(dirname "$file_path")/.${file_path##*/}.strip-comments.XXXXXX")" || return 2

  if ! awk '
    BEGIN {
      squote = sprintf("%c", 39)
      xml_comment = 0
    }

    function previous_starts_comment(prev) {
      return prev == "" || prev ~ /[[:space:]]/
    }

    function remove_xml_comments(line,    start, stop, prefix, suffix) {
      while (xml_comment || match(line, /<!--/)) {
        if (xml_comment) {
          stop = index(line, "-->")
          if (!stop) {
            return ""
          }
          line = substr(line, stop + 3)
          xml_comment = 0
          continue
        }

        start = RSTART
        prefix = substr(line, 1, start - 1)
        suffix = substr(line, start)

        stop = index(suffix, "-->")
        if (!stop) {
          xml_comment = 1
          return prefix
        }
        line = prefix substr(suffix, stop + 3)
      }

      return line
    }

    function strip_hash_comment(line,    i, c, prev, prefix, quote, escaped) {
      quote = ""
      escaped = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)

        if (escaped) {
          escaped = 0
          continue
        }

        if (quote == squote) {
          if (c == squote) {
            quote = ""
          }
          continue
        }

        if (quote == "\"") {
          if (c == "\\") {
            escaped = 1
            continue
          }
          if (c == "\"") {
            quote = ""
          }
          continue
        }

        if (c == "\\") {
          escaped = 1
          continue
        }
        if (c == squote) {
          quote = squote
          continue
        }
        if (c == "\"") {
          quote = "\""
          continue
        }
        if (c == "#") {
          prev = i == 1 ? "" : substr(line, i - 1, 1)
          if (previous_starts_comment(prev)) {
            prefix = substr(line, 1, i - 1)
            sub(/[[:space:]]+$/, "", prefix)
            return prefix
          }
        }
      }
      return line
    }

    {
      line = remove_xml_comments($0)
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)
      if (trimmed ~ /^(#|;)/ || trimmed == "") {
        next
      }
      line = strip_hash_comment(line)
      if (line != "") {
        print line
      }
    }
  ' "$file_path" >"$tmp_path"; then
    rm -f "$tmp_path"
    return 2
  fi

  rewrite_file_if_changed "$file_path" "$tmp_path"
}

find_sysroot_files() {
  find "$SYSROOT_DIR" \
    \( -path "$SYSROOT_DIR/proc" -o -path "$SYSROOT_DIR/sys" -o -path "$SYSROOT_DIR/dev" -o -path "$SYSROOT_DIR/run" \) -prune \
    -o -type f -print0
}

strip_sysroot_comments() {
  local -A shell_files=()
  local file_path
  local shell_total=0
  local shell_changed=0
  local config_total=0
  local config_changed=0
  local status

  echo "Stripping comments from sysroot shell scripts and config files"

  while IFS= read -r -d '' file_path; do
    if is_shell_script_path "$file_path" || has_shell_shebang "$file_path"; then
      shell_files["$file_path"]=1
      shell_total=$((shell_total + 1))
      if strip_shell_comments "$file_path"; then
        shell_changed=$((shell_changed + 1))
      else
        status=$?
        [ "$status" -eq 1 ] || return "$status"
      fi
    fi
  done < <(find_sysroot_files)

  while IFS= read -r -d '' file_path; do
    if [ "${shell_files[$file_path]+set}" = set ]; then
      continue
    fi
    is_config_path "$file_path" || continue
    config_total=$((config_total + 1))
    if strip_config_comments "$file_path"; then
      config_changed=$((config_changed + 1))
    else
      status=$?
      [ "$status" -eq 1 ] || return "$status"
    fi
  done < <(find_sysroot_files)

  echo "Shell scripts changed: $shell_changed/$shell_total"
  echo "Config files changed: $config_changed/$config_total"
}

write_download_reinstall_script() {
  local target="$SYSROOT_DIR/usr/bin/download_reinstall"

  mkdir -p "$(dirname "$target")"
  cat >"$target" <<EOF
#!/bin/sh

set -eu

url='$REINSTALL_SCRIPT_URL'
target=./reinstall.sh
tmp="\$target.tmp.\$\$"

cleanup() {
  rm -f "\$tmp"
}

trap cleanup EXIT HUP INT TERM

if command -v curl >/dev/null 2>&1; then
  curl -fL -o "\$tmp" "\$url"
elif command -v wget >/dev/null 2>&1; then
  wget -O "\$tmp" "\$url"
elif [ -x /usr/bin/busybox ]; then
  /usr/bin/busybox wget -O "\$tmp" "\$url"
else
  echo "error: curl, wget, or busybox wget is required" >&2
  exit 1
fi

chmod 755 "\$tmp"
mv -f "\$tmp" "\$target"
trap - EXIT HUP INT TERM

echo "Downloaded ./reinstall.sh"
echo "Run it with: ./reinstall.sh"
EOF
  chmod 755 "$target"
  echo "Configured $target"
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
  local latest requested

  if [ -n "$UBUNTU_BASE_TARBALL" ]; then
    case "$UBUNTU_BASE_TARBALL" in
      /*)
        requested=$UBUNTU_BASE_TARBALL
        ;;
      *)
        requested="$ROOT_DIR/$UBUNTU_BASE_TARBALL"
        ;;
    esac
    [ -f "$requested" ] || return 1
    printf '%s\n' "$requested"
    return 0
  fi

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

read_os_release_value() {
  local key=$1
  local file="$SYSROOT_DIR/etc/os-release"

  [ -r "$file" ] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, length(key) + 2)
      if (value ~ /^"/) {
        sub(/^"/, "", value)
        sub(/"$/, "", value)
      }
      print value
      exit
    }
  ' "$file"
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)
      [ "$RESET_SYSROOT_MODE" = ask ] || usage
      RESET_SYSROOT_MODE=yes
      ;;
    -n|--no)
      [ "$RESET_SYSROOT_MODE" = ask ] || usage
      RESET_SYSROOT_MODE=no
      ;;
    --strip-comments)
      STRIP_SYSROOT_COMMENTS=yes
      ;;
    -h|--help)
      usage 0
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
  shift
done

[ "$#" -eq 0 ] || usage

echo "Setting up sysroot for initramfs"

prepare_base_sysroot

UBUNTU_PRETTY_NAME="$(read_os_release_value PRETTY_NAME || true)"
UBUNTU_VERSION_ID="$(read_os_release_value VERSION_ID || true)"
UBUNTU_CODENAME="$(read_os_release_value VERSION_CODENAME || true)"
if [ -z "$UBUNTU_CODENAME" ]; then
  UBUNTU_CODENAME="$(read_os_release_value UBUNTU_CODENAME || true)"
fi

[ -n "$UBUNTU_PRETTY_NAME" ] || UBUNTU_PRETTY_NAME="Ubuntu ${UBUNTU_VERSION_ID:-unknown}"
[ -n "$UBUNTU_CODENAME" ] || die "could not detect Ubuntu codename from $SYSROOT_DIR/etc/os-release"

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
${UBUNTU_PRETTY_NAME} \n \l

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
Suites: @UBUNTU_CODENAME@ @UBUNTU_CODENAME@-updates @UBUNTU_CODENAME@-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://mirrors4.tuna.tsinghua.edu.cn/ubuntu
Suites: @UBUNTU_CODENAME@-security
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
Suites: @UBUNTU_CODENAME@ @UBUNTU_CODENAME@-updates @UBUNTU_CODENAME@-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: @UBUNTU_CODENAME@-security
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

sed -i "s/@UBUNTU_CODENAME@/${UBUNTU_CODENAME}/g" "$SYSROOT_DIR/mirror.sh"
chmod 755 "$SYSROOT_DIR/mirror.sh"
install -Dm755 "$ROOT_DIR/script/init" "$SYSROOT_DIR/init"
install -Dm755 "$ROOT_DIR/script/udhcpc.default.script" "$SYSROOT_DIR/usr/share/udhcpc/default.script"
write_download_reinstall_script

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
  "$SYSROOT_DIR/etc/systemd/system/serial-getty@ttyS0.service.d" \
  "$SYSROOT_DIR/etc/systemd/system/getty@tty1.service.d" \
  "$SYSROOT_DIR/etc/systemd/system/getty@ttyS0.service.d"
rm -f \
  "$SYSROOT_DIR/etc/systemd/system/getty.target.wants/getty@tty1.service" \
  "$SYSROOT_DIR/etc/systemd/system/getty.target.wants/getty@ttyS0.service" \
  "$SYSROOT_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" \
  "$SYSROOT_DIR/etc/systemd/system/getty.target.wants/root-shell@tty1.service" \
  "$SYSROOT_DIR/etc/systemd/system/getty.target.wants/root-shell@ttyS0.service" \
  "$SYSROOT_DIR/etc/systemd/system/root-shell@.service"

mkdir -p "$SYSROOT_DIR/etc/systemd/system/getty@tty1.service.d"
cat >"$SYSROOT_DIR/etc/systemd/system/getty@tty1.service.d/autologin-root.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin root --noclear %I $TERM
TTYVTDisallocate=no
EOF

mkdir -p "$SYSROOT_DIR/etc/systemd/system/getty@ttyS0.service.d"
cat >"$SYSROOT_DIR/etc/systemd/system/getty@ttyS0.service.d/autologin-root.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/sbin/agetty --autologin root --noclear --keep-baud 115200,57600,38400,9600 %I $TERM
EOF

mkdir -p "$SYSROOT_DIR/etc/systemd/system/getty.target.wants"
ln -sfn /lib/systemd/system/getty@.service "$SYSROOT_DIR/etc/systemd/system/getty.target.wants/getty@tty1.service"
ln -sfn /lib/systemd/system/getty@.service "$SYSROOT_DIR/etc/systemd/system/getty.target.wants/getty@ttyS0.service"
echo "Configured root autologin gettys on tty1 and ttyS0"

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

if [ "$STRIP_SYSROOT_COMMENTS" = yes ]; then
  strip_sysroot_comments
fi
