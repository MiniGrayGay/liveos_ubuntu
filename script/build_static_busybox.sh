#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/busybox-static"
SRC_CACHE_DIR="$BUILD_DIR/src"
ARTIFACT_DIR="$BUILD_DIR/artifacts"

BUSYBOX_VER="${BUSYBOX_VER:-1.38.0}"
BUSYBOX_TARBALL="busybox-${BUSYBOX_VER}.tar.bz2"
BUSYBOX_URL="https://busybox.net/downloads/${BUSYBOX_TARBALL}"

ZSTD_VER="${ZSTD_VER:-1.5.7}"
ZSTD_TARBALL="zstd-${ZSTD_VER}.tar.gz"
ZSTD_URL="${ZSTD_URL:-https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/${ZSTD_TARBALL}}"

MBEDTLS_VER="${MBEDTLS_VER:-3.6.6}"
MBEDTLS_TAG="${MBEDTLS_TAG:-v${MBEDTLS_VER}}"
MBEDTLS_GIT_URL="${MBEDTLS_GIT_URL:-https://github.com/Mbed-TLS/mbedtls.git}"
MBEDTLS_SRC_DIR="$BUILD_DIR/mbedtls-src"

JOBS="${JOBS:-$(nproc)}"
SIZE_CFLAGS="${SIZE_CFLAGS:--Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables}"
SIZE_LDFLAGS="${SIZE_LDFLAGS:--static -Wl,--gc-sections -s}"

NATIVE_CC="${NATIVE_CC:-musl-gcc}"
NATIVE_STRIP="${NATIVE_STRIP:-strip}"
AARCH64_STRIP="${AARCH64_STRIP:-}"
AARCH64_LINUX_HEADERS="${AARCH64_LINUX_HEADERS:-/usr/aarch64-linux-gnu/include}"
MBEDTLS_MODE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--mbedTLS]

Build static BusyBox binaries for native amd64 and aarch64.

Options:
  --mbedTLS, --mbedtls  Use an embedded mbedTLS-backed openssl helper for wget.
                        This mode supports TLS 1.2 and TLS 1.3 only, disables
                        BusyBox's built-in TLS applets, and does not use UPX.
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mbedTLS|--mbedtls)
      MBEDTLS_MODE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

have_tool() {
  command -v "$1" >/dev/null 2>&1
}

install_package() {
  local package=$1

  if ! have_tool pacman; then
    return 1
  fi

  echo "Installing missing package: $package" >&2
  pacman -Sy --needed --noconfirm "$package"
}

require_tool() {
  local tool=$1
  local package=${2:-$1}

  if have_tool "$tool"; then
    return 0
  fi

  install_package "$package" || true

  if ! have_tool "$tool"; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

select_aarch64_cc() {
  if [[ -n "${AARCH64_CC:-}" ]]; then
    require_tool "$AARCH64_CC"
    printf '%s\n' "$AARCH64_CC"
    return 0
  fi

  if have_tool aarch64-linux-musl-gcc; then
    printf '%s\n' "aarch64-linux-musl-gcc"
    return 0
  fi

  if ! have_tool aarch64-linux-gnu-gcc; then
    install_package aarch64-linux-gnu-gcc || true
  fi

  if have_tool aarch64-linux-gnu-gcc; then
    printf '%s\n' "aarch64-linux-gnu-gcc"
    return 0
  fi

  echo "Missing aarch64 cross compiler: aarch64-linux-musl-gcc or aarch64-linux-gnu-gcc" >&2
  exit 1
}

select_strip() {
  local cc=$1

  case "$cc" in
    aarch64-linux-musl-gcc)
      if [[ -n "$AARCH64_STRIP" ]]; then
        printf '%s\n' "$AARCH64_STRIP"
      elif have_tool aarch64-linux-musl-strip; then
        printf '%s\n' "aarch64-linux-musl-strip"
      elif have_tool aarch64-linux-gnu-strip; then
        printf '%s\n' "aarch64-linux-gnu-strip"
      else
        printf '%s\n' "strip"
      fi
      ;;
    aarch64-linux-gnu-gcc)
      printf '%s\n' "${AARCH64_STRIP:-aarch64-linux-gnu-strip}"
      ;;
    *)
      printf '%s\n' "$NATIVE_STRIP"
      ;;
  esac
}

select_binutils_tool() {
  local cc=$1
  local suffix=$2
  local fallback=$3
  local prefix candidate

  if [[ "$cc" == *gcc ]]; then
    prefix="${cc%gcc}"
    candidate="${prefix}${suffix}"
    if have_tool "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if have_tool "$fallback"; then
    printf '%s\n' "$fallback"
    return 0
  fi

  echo "Missing required tool for $cc: ${prefix:-}<prefix>${suffix} or $fallback" >&2
  exit 1
}

prepare_aarch64_musl_uapi_overlay() {
  local overlay="$BUILD_DIR/aarch64-musl-uapi"

  if [[ ! -d "$AARCH64_LINUX_HEADERS/linux" || ! -d "$AARCH64_LINUX_HEADERS/asm" ]]; then
    install_package aarch64-linux-gnu-linux-api-headers || true
  fi

  if [[ ! -d "$AARCH64_LINUX_HEADERS/linux" || ! -d "$AARCH64_LINUX_HEADERS/asm" ]]; then
    echo "Missing aarch64 Linux UAPI headers under $AARCH64_LINUX_HEADERS" >&2
    exit 1
  fi

  mkdir -p "$overlay"
  local uapi_dirs=(
    asm asm-generic cxl drm fwctl linux misc mtd nfs rdma regulator sound video xen
  )
  local dir
  for dir in "${uapi_dirs[@]}"; do
    if [[ -d "$AARCH64_LINUX_HEADERS/$dir" ]]; then
      ln -sfn "$AARCH64_LINUX_HEADERS/$dir" "$overlay/$dir"
    fi
  done

  printf '%s\n' "$overlay"
}

fetch() {
  local url=$1
  local dest=$2

  if [[ ! -f "$dest" ]]; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  fi
}

config_set() {
  local config_path=$1
  local key=$2
  local value=$3
  local tmp="${config_path}.tmp"

  awk -v key="$key" -v value="$value" '
    BEGIN {
      replacement = (value == "n") ? "# " key " is not set" : key "=" value
    }
    $0 == "# " key " is not set" || index($0, key "=") == 1 {
      if (!matched) {
        print replacement
        matched = 1
      }
      next
    }
    { print }
    END {
      if (!matched) {
        print replacement
      }
    }
  ' "$config_path" >"$tmp"
  mv "$tmp" "$config_path"
}

static_link_works() {
  local cc=$1
  local ldflags=$2
  local extra_ldflags=$3
  local test_dir=$4
  local test_c="$test_dir/conftest.c"
  local test_bin="$test_dir/conftest"

  printf 'int main(void) { return 0; }\n' >"$test_c"

  # SIZE_CFLAGS/SIZE_LDFLAGS are shell-style flag lists by design.
  # shellcheck disable=SC2086
  "$cc" $SIZE_CFLAGS $ldflags $extra_ldflags "$test_c" -o "$test_bin" >/dev/null 2>&1
}

resolve_static_ldflags() {
  local target=$1
  local cc=$2
  local test_dir

  test_dir=$(mktemp -d "${TMPDIR:-/tmp}/busybox-${target}-link.XXXXXX")

  if static_link_works "$cc" "$SIZE_LDFLAGS" "" "$test_dir"; then
    rm -rf "$test_dir"
    printf '%s\n' "$SIZE_LDFLAGS"
    return 0
  fi

  if static_link_works "$cc" "$SIZE_LDFLAGS" "-fno-link-libatomic" "$test_dir"; then
    rm -rf "$test_dir"
    echo "Added -fno-link-libatomic for $target static linking" >&2
    printf '%s\n' "$SIZE_LDFLAGS -fno-link-libatomic"
    return 0
  fi

  rm -rf "$test_dir"
  echo "$cc cannot create a static executable with the configured flags" >&2
  echo "Try running: $cc $SIZE_CFLAGS $SIZE_LDFLAGS /tmp/conftest.c -o /tmp/conftest" >&2
  return 1
}

zstd_source_dir() {
  local target=$1

  printf '%s\n' "$BUILD_DIR/zstd-src-$target"
}

zstd_ldlibs_for_target() {
  local target=$1
  local src_dir

  src_dir="$(zstd_source_dir "$target")"
  printf '%s\n' "-L$src_dir/lib -lzstd"
}

build_zstd_for_target() {
  local target=$1
  local cc=$2
  local cflags=$3
  local ldflags=$4
  local src_dir
  local ar
  local ranlib

  src_dir="$(zstd_source_dir "$target")"
  ar="$(select_binutils_tool "$cc" ar ar)"
  ranlib="$(select_binutils_tool "$cc" ranlib ranlib)"

  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar -xf "$SRC_CACHE_DIR/$ZSTD_TARBALL" -C "$src_dir" --strip-components=1

  echo
  echo "Building zstd $ZSTD_VER decompressor library for $target with $cc"
  make -C "$src_dir/lib" -j"$JOBS" \
    CC="$cc" \
    AR="$ar" \
    RANLIB="$ranlib" \
    CFLAGS="$cflags -DNDEBUG" \
    LDFLAGS="$ldflags" \
    ZSTD_LIB_COMPRESSION=0 \
    ZSTD_LIB_DECOMPRESSION=1 \
    ZSTD_LIB_DICTBUILDER=0 \
    ZSTD_LIB_DEPRECATED=0 \
    ZSTD_LEGACY_SUPPORT=0 \
    libzstd.a
}

patch_zstd_applet() {
  local src_dir=$1
  local zstd_c="$src_dir/archival/zstd.c"

  cat >"$zstd_c" <<'EOF_ZSTD_APPLET'
/*
 * Decompression-only zstd applets backed by libzstd.
 *
 * Supports:
 *   zstd -d [-c] FILE...
 *   unzstd [-c] FILE...
 *   zstdcat FILE...
 */
//config:config ZSTD
//config:	bool "zstd -d (decompress only)"
//config:	default y
//config:	help
//config:	Decompress zstd streams using the bundled static libzstd.
//config:
//config:config UNZSTD
//config:	bool "unzstd"
//config:	default y
//config:	help
//config:	Alias for zstd -d.
//config:
//config:config ZSTDCAT
//config:	bool "zstdcat"
//config:	default y
//config:	help
//config:	Alias for zstd -dc.

//applet:IF_ZSTD(   APPLET(zstd, BB_DIR_BIN, BB_SUID_DROP))
//                  APPLET_ODDNAME:name    main  location        suid_type     help
//applet:IF_UNZSTD( APPLET_ODDNAME(unzstd,  zstd, BB_DIR_USR_BIN, BB_SUID_DROP, unzstd))
//applet:IF_ZSTDCAT(APPLET_ODDNAME(zstdcat, zstd, BB_DIR_USR_BIN, BB_SUID_DROP, zstdcat))

//kbuild:lib-$(CONFIG_ZSTD) += zstd.o
//kbuild:lib-$(CONFIG_UNZSTD) += zstd.o
//kbuild:lib-$(CONFIG_ZSTDCAT) += zstd.o

//usage:#define zstd_trivial_usage
//usage:       "-d [-cf] [FILE]..."
//usage:#define zstd_full_usage "\n\n"
//usage:       "	-d	Decompress"
//usage:     "\n	-c	Write to stdout"
//usage:     "\n	-f	Force overwrite"
//usage:#define unzstd_trivial_usage
//usage:       "[-cf] [FILE]..."
//usage:#define unzstd_full_usage "\n\n"
//usage:       "	-c	Write to stdout"
//usage:     "\n	-f	Force overwrite"
//usage:#define zstdcat_trivial_usage
//usage:       "[FILE]..."
//usage:#define zstdcat_full_usage ""

#include "libbb.h"
#include "bb_archive.h"

enum {
	OPT_DECOMPRESS = 1 << 0,
	OPT_STDOUT = 1 << 1,
	OPT_FORCE = 1 << 2,
};

static int has_suffix(const char *name, const char *suffix)
{
	size_t name_len = strlen(name);
	size_t suffix_len = strlen(suffix);

	return name_len > suffix_len
	 && strcmp(name + name_len - suffix_len, suffix) == 0;
}

static char *make_output_name(const char *name)
{
	size_t len = strlen(name);

	if (has_suffix(name, ".zst"))
		return xstrndup(name, len - 4);
	if (has_suffix(name, ".zstd"))
		return xstrndup(name, len - 5);
	return NULL;
}

static int decompress_fd(int infd, int outfd)
{
	transformer_state_t xstate;

	init_transformer_state(&xstate);
	xstate.src_fd = infd;
	xstate.dst_fd = outfd;
	return unpack_zstd_stream(&xstate) < 0;
}

static int open_output_file(const char *input_name, unsigned opts)
{
	char *output_name;
	int flags = O_WRONLY | O_CREAT;
	int fd;

	output_name = make_output_name(input_name);
	if (!output_name)
		bb_error_msg_and_die("%s: unknown suffix", input_name);

	if (opts & OPT_FORCE)
		flags |= O_TRUNC;
	else
		flags |= O_EXCL;

	fd = xopen3(output_name, flags, 0666);
	free(output_name);
	return fd;
}

static unsigned parse_options(char ***argvp)
{
	char **argv = *argvp;
	unsigned opts = 0;

	if (strcmp(applet_name, "zstdcat") == 0)
		opts |= OPT_DECOMPRESS | OPT_STDOUT;
	else if (strcmp(applet_name, "unzstd") == 0)
		opts |= OPT_DECOMPRESS;

	while (*argv) {
		char *arg = *argv;
		char *p;

		if (LONE_DASH(arg))
			break;
		if (strcmp(arg, "--") == 0) {
			argv++;
			break;
		}
		if (strcmp(arg, "--decompress") == 0) {
			opts |= OPT_DECOMPRESS;
			argv++;
			continue;
		}
		if (strcmp(arg, "--stdout") == 0 || strcmp(arg, "--to-stdout") == 0) {
			opts |= OPT_STDOUT;
			argv++;
			continue;
		}
		if (strcmp(arg, "--force") == 0) {
			opts |= OPT_FORCE;
			argv++;
			continue;
		}
		if (arg[0] != '-' || arg[1] == '\0')
			break;

		for (p = arg + 1; *p; p++) {
			if (*p == 'd')
				opts |= OPT_DECOMPRESS;
			else if (*p == 'c')
				opts |= OPT_STDOUT;
			else if (*p == 'f')
				opts |= OPT_FORCE;
			else if (*p == 'q')
				continue;
			else
				bb_show_usage();
		}
		argv++;
	}

	*argvp = argv;
	return opts;
}

int zstd_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
int zstd_main(int argc UNUSED_PARAM, char **argv)
{
	unsigned opts;
	int exitcode = 0;

	argv++;
	opts = parse_options(&argv);
	if (!(opts & OPT_DECOMPRESS))
		bb_simple_error_msg_and_die("compression is not supported");

	if (!*argv) {
		exitcode |= decompress_fd(STDIN_FILENO, STDOUT_FILENO);
		return exitcode;
	}

	do {
		const char *name = *argv;
		int infd = STDIN_FILENO;
		int outfd = STDOUT_FILENO;

		if (!LONE_DASH(name))
			infd = xopen(name, O_RDONLY);
		if (!(opts & OPT_STDOUT) && !LONE_DASH(name))
			outfd = open_output_file(name, opts);

		exitcode |= decompress_fd(infd, outfd);

		if (outfd != STDOUT_FILENO)
			close(outfd);
		if (infd != STDIN_FILENO)
			close(infd);
	} while (*++argv);

	return exitcode;
}
EOF_ZSTD_APPLET

  cat >"$src_dir/archival/libarchive/decompress_unzstd.c" <<'EOF_ZSTD_TRANSFORMER'
/*
 * Decompression-only zstd transformer backed by libzstd.
 *
 * Licensed under GPLv2, see file LICENSE in this source tree.
 */
#include "libbb.h"
#include "bb_archive.h"

#include <zstd.h>

IF_DESKTOP(long long) int FAST_FUNC
unpack_zstd_stream(transformer_state_t *xstate)
{
	ZSTD_DStream *stream;
	void *inbuf;
	void *outbuf;
	size_t insize;
	size_t outsize;
	size_t remaining = 1;
	size_t in_pos = 0;
	size_t in_size = 0;
	IF_DESKTOP(long long) int total = 0;

	stream = ZSTD_createDStream();
	if (!stream) {
		bb_simple_error_msg("ZSTD_createDStream failed");
		return -1;
	}

	insize = ZSTD_DStreamInSize();
	outsize = ZSTD_DStreamOutSize();
	inbuf = xmalloc(insize);
	outbuf = xmalloc(outsize);

	if (ZSTD_isError(ZSTD_initDStream(stream))) {
		bb_simple_error_msg("ZSTD_initDStream failed");
		total = -1;
		goto out;
	}

	if (xstate->signature_skipped) {
		static const unsigned char zstd_magic[] = { 0x28, 0xb5, 0x2f, 0xfd };
		memcpy(inbuf, zstd_magic, sizeof(zstd_magic));
		in_size = sizeof(zstd_magic);
	}

	for (;;) {
		ZSTD_inBuffer input;

		if (in_pos == in_size) {
			ssize_t rd = safe_read(xstate->src_fd, inbuf, insize);
			if (rd < 0) {
				bb_simple_perror_msg("read");
				total = -1;
				break;
			}
			if (rd == 0)
				break;
			in_size = (size_t)rd;
			in_pos = 0;
		}

		input.src = inbuf;
		input.size = in_size;
		input.pos = in_pos;
		while (input.pos < input.size) {
			ZSTD_outBuffer output;

			output.dst = outbuf;
			output.size = outsize;
			output.pos = 0;
			remaining = ZSTD_decompressStream(stream, &output, &input);
			if (ZSTD_isError(remaining)) {
				bb_error_msg("zstd: %s", ZSTD_getErrorName(remaining));
				total = -1;
				goto out;
			}
			if (output.pos) {
				xtransformer_write(xstate, outbuf, output.pos);
				IF_DESKTOP(total += output.pos;)
			}
		}
		in_pos = input.pos;
	}

	if (total >= 0 && remaining != 0) {
		bb_simple_error_msg("zstd: unexpected end of file");
		total = -1;
	}

 out:
	ZSTD_freeDStream(stream);
	free(inbuf);
	free(outbuf);
	return total;
}
EOF_ZSTD_TRANSFORMER

  awk '
    { print }
    /XZ_MAGIC2   =/ && !inserted_be {
      print "\tZSTD_MAGIC1 = 256 * 0x28 + 0xb5,"
      print "\tZSTD_MAGIC2 = 256 * 0x2f + 0xfd,"
      inserted_be = 1
    }
    /XZ_MAGIC2   =/ && inserted_be && !seen_else {
      next
    }
    /#else/ { seen_else = 1 }
    seen_else && /XZ_MAGIC2   =/ && !inserted_le {
      print "\tZSTD_MAGIC1 = 0x28 + 0xb5 * 256,"
      print "\tZSTD_MAGIC2 = 0x2f + 0xfd * 256,"
      inserted_le = 1
    }
    /IF_DESKTOP\(long long\) int unpack_xz_stream/ && !inserted_proto {
      print "IF_DESKTOP(long long) int unpack_zstd_stream(transformer_state_t *xstate) FAST_FUNC;"
      inserted_proto = 1
    }
  ' "$src_dir/include/bb_archive.h" >"$src_dir/include/bb_archive.h.tmp"
  mv "$src_dir/include/bb_archive.h.tmp" "$src_dir/include/bb_archive.h"

  awk '
    {
      print
      if ($0 ~ /\|\| ENABLE_FEATURE_SEAMLESS_XZ \\/ && !inserted) {
        print " || ENABLE_FEATURE_SEAMLESS_ZSTD \\"
        inserted = 1
      }
    }
  ' "$src_dir/include/libbb.h" >"$src_dir/include/libbb.h.tmp"
  mv "$src_dir/include/libbb.h.tmp" "$src_dir/include/libbb.h"

  awk '
    /^config FEATURE_LZMA_FAST/ && !inserted_config {
      print "config FEATURE_SEAMLESS_ZSTD"
      print "\tbool \"Make tar, rpm, modprobe etc understand .zst data\""
      print "\tdefault y"
      print "\thelp"
      print "\t  Make tar and related applets understand zstd-compressed data."
      print ""
      inserted_config = 1
    }
    { print }
  ' "$src_dir/archival/Config.src" >"$src_dir/archival/Config.src.tmp"
  mv "$src_dir/archival/Config.src.tmp" "$src_dir/archival/Config.src"

  awk '
    {
      gsub(/FEATURE_SEAMLESS_XZ\)/, "FEATURE_SEAMLESS_XZ || FEATURE_SEAMLESS_ZSTD)")
      print
    }
  ' "$src_dir/archival/tar.c" >"$src_dir/archival/tar.c.tmp"
  mv "$src_dir/archival/tar.c.tmp" "$src_dir/archival/tar.c"

  awk '
    { print }
    /lib-\$\(CONFIG_FEATURE_SEAMLESS_XZ\).*decompress_unxz\.o/ && !inserted {
      print "lib-$(CONFIG_FEATURE_SEAMLESS_ZSTD)      += open_transformer.o decompress_unzstd.o"
      inserted = 1
    }
  ' "$src_dir/archival/libarchive/Kbuild.src" >"$src_dir/archival/libarchive/Kbuild.src.tmp"
  mv "$src_dir/archival/libarchive/Kbuild.src.tmp" "$src_dir/archival/libarchive/Kbuild.src"

  awk '
    /if \(ENABLE_FEATURE_SEAMLESS_XZ/ { in_xz = 1 }
    { print }
    in_xz && /^	}/ {
      print "\tif (ENABLE_FEATURE_SEAMLESS_ZSTD"
      print "\t && xstate->magic.b16[0] == ZSTD_MAGIC1"
      print "\t) {"
      print "\t\txstate->signature_skipped = 4;"
      print "\t\txread(fd, &xstate->magic.b16[1], 2);"
      print "\t\tif (xstate->magic.b16[1] == ZSTD_MAGIC2) {"
      print "\t\t\txstate->xformer = unpack_zstd_stream;"
      print "\t\t\tUSE_FOR_NOMMU(xstate->xformer_prog = \"unzstd\";)"
      print "\t\t\tgoto found_magic;"
      print "\t\t}"
      print "\t}"
      in_xz = 0
    }
  ' "$src_dir/archival/libarchive/open_transformer.c" >"$src_dir/archival/libarchive/open_transformer.c.tmp"
  mv "$src_dir/archival/libarchive/open_transformer.c.tmp" "$src_dir/archival/libarchive/open_transformer.c"

  awk '
    {
      if (index($0, "IF_FEATURE_SEAMLESS_XZ(\"/xz\")") != 0)
        print "\t\t\tIF_FEATURE_SEAMLESS_ZSTD(\"/zstd\")"
      print
    }
  ' "$src_dir/archival/libarchive/open_transformer.c" >"$src_dir/archival/libarchive/open_transformer.c.tmp"
  mv "$src_dir/archival/libarchive/open_transformer.c.tmp" "$src_dir/archival/libarchive/open_transformer.c"
}

prepare_mbedtls_source() {
  if [[ -d "$MBEDTLS_SRC_DIR/.git" ]]; then
    if [[ "$(git -C "$MBEDTLS_SRC_DIR" describe --tags --exact-match 2>/dev/null || true)" == "$MBEDTLS_TAG" ]]; then
      git -C "$MBEDTLS_SRC_DIR" submodule update --init --depth 1
      return 0
    fi

    git -C "$MBEDTLS_SRC_DIR" fetch --depth 1 origin "refs/tags/${MBEDTLS_TAG}:refs/tags/${MBEDTLS_TAG}" || \
      git -C "$MBEDTLS_SRC_DIR" fetch --depth 1 origin "$MBEDTLS_TAG"
    git -C "$MBEDTLS_SRC_DIR" checkout -q "$MBEDTLS_TAG"
  else
    rm -rf "$MBEDTLS_SRC_DIR"
    git clone --depth 1 --branch "$MBEDTLS_TAG" "$MBEDTLS_GIT_URL" "$MBEDTLS_SRC_DIR"
  fi

  git -C "$MBEDTLS_SRC_DIR" submodule update --init --depth 1
}

mbedtls_build_dir() {
  local target=$1

  printf '%s\n' "$BUILD_DIR/mbedtls-build-$target"
}

mbedtls_ldlibs_for_target() {
  local target=$1
  local build_dir

  build_dir="$(mbedtls_build_dir "$target")"
  printf '%s\n' "-L$build_dir/library -L$build_dir/3rdparty/everest -L$build_dir/3rdparty/p256-m -lmbedtls -lmbedx509 -lmbedcrypto -leverest -lp256m"
}

build_mbedtls_for_target() {
  local target=$1
  local cc=$2
  local cflags=$3
  local ldflags=$4
  local build_dir
  local -a generator_args=()
  local -a cross_args=()

  build_dir="$(mbedtls_build_dir "$target")"
  rm -rf "$build_dir"

  if have_tool ninja; then
    generator_args=(-G Ninja)
  fi

  if [[ "$target" == "aarch64" ]]; then
    cross_args=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64)
  fi

  echo
  echo "Building mbedTLS $MBEDTLS_TAG for $target with $cc"
  cmake -S "$MBEDTLS_SRC_DIR" -B "$build_dir" \
    "${generator_args[@]}" \
    "${cross_args[@]}" \
    -DCMAKE_BUILD_TYPE=Check \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_C_FLAGS="$cflags -fno-link-libatomic -DNDEBUG" \
    -DCMAKE_EXE_LINKER_FLAGS="$ldflags -fno-link-libatomic" \
    -DMBEDTLS_FATAL_WARNINGS=OFF \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF
  cmake --build "$build_dir" --target mbedtls mbedx509 mbedcrypto -j "$JOBS"
}

patch_mbedtls_openssl_applet() {
  local src_dir=$1
  local openssl_c="$src_dir/networking/openssl.c"

  cat >"$openssl_c" <<'EOF_MBEDTLS_OPENSSL'
/*
 * Minimal openssl s_client compatible applet backed by mbedTLS.
 *
 * This implements the subset emitted by networking/wget.c:
 *   openssl s_client -quiet -connect HOST:PORT [-servername HOST] ...
 */
//applet:APPLET(openssl, BB_DIR_USR_BIN, BB_SUID_DROP)

//kbuild:lib-y += openssl.o

//usage:#define openssl_trivial_usage
//usage:       "s_client -quiet -connect HOST:PORT [-servername HOST]"
//usage:#define openssl_full_usage ""

#include "libbb.h"

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/ssl.h>

#include <arpa/inet.h>
#include <netinet/in.h>

struct tls_fd {
	int fd;
};

static int fd_send(void *ctx, const unsigned char *buf, size_t len)
{
	struct tls_fd *tls_fd = ctx;
	ssize_t ret;

	ret = write(tls_fd->fd, buf, len);
	if (ret < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
			return MBEDTLS_ERR_SSL_WANT_WRITE;
		return -1;
	}
	return ret;
}

static int fd_recv(void *ctx, unsigned char *buf, size_t len)
{
	struct tls_fd *tls_fd = ctx;
	ssize_t ret;

	ret = read(tls_fd->fd, buf, len);
	if (ret < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
			return MBEDTLS_ERR_SSL_WANT_READ;
		return -1;
	}
	if (ret == 0)
		return MBEDTLS_ERR_SSL_CONN_EOF;
	return ret;
}

static void split_host_port(char *hostport, char **host, int *port)
{
	char *colon;

	*host = hostport;
	*port = 443;

	colon = strrchr(hostport, ':');
	if (!colon)
		return;

	*colon = '\0';
	*port = xatou16(colon + 1);
}

static void tls_die(int ret, const char *where)
{
	char errbuf[128];

	mbedtls_strerror(ret, errbuf, sizeof(errbuf));
	bb_error_msg_and_die("%s: -0x%04x: %s", where, -ret, errbuf);
}

static int looks_like_ip_address(const char *string)
{
	struct sockaddr_in sa;
	int result = inet_pton(AF_INET, string, &sa.sin_addr);
#if ENABLE_FEATURE_IPV6
	if (result == 0) {
		struct sockaddr_in6 sa6;
		result = inet_pton(AF_INET6, string, &sa6.sin6_addr);
	}
#endif
	return result == 1;
}

static int pump_tls(mbedtls_ssl_context *ssl, int net_fd)
{
	int local_open = 1;

	for (;;) {
		fd_set rfds;
		int maxfd = net_fd;
		int ret;

		FD_ZERO(&rfds);
		if (local_open) {
			FD_SET(STDIN_FILENO, &rfds);
			if (maxfd < STDIN_FILENO)
				maxfd = STDIN_FILENO;
		}
		FD_SET(net_fd, &rfds);

		ret = select(maxfd + 1, &rfds, NULL, NULL, NULL);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			bb_simple_perror_msg_and_die("select");
		}

		if (local_open && FD_ISSET(STDIN_FILENO, &rfds)) {
			unsigned char buf[4096];
			ssize_t rd = read(STDIN_FILENO, buf, sizeof(buf));
			size_t off = 0;

			if (rd < 0) {
				if (errno == EINTR)
					continue;
				bb_simple_perror_msg_and_die("read");
			}
			if (rd == 0) {
				local_open = 0;
				continue;
			}
			while (off < (size_t)rd) {
				ret = mbedtls_ssl_write(ssl, buf + off, (size_t)rd - off);
				if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
					continue;
				if (ret < 0)
					tls_die(ret, "mbedtls_ssl_write");
				off += ret;
			}
		}

		if (FD_ISSET(net_fd, &rfds)) {
			unsigned char buf[4096];

			ret = mbedtls_ssl_read(ssl, buf, sizeof(buf));
			if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
				continue;
			if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || ret == MBEDTLS_ERR_SSL_CONN_EOF)
				return 0;
			if (ret < 0)
				tls_die(ret, "mbedtls_ssl_read");
			if (ret == 0)
				return 0;
			full_write(STDOUT_FILENO, buf, ret);
		}
	}
}

int openssl_main(int argc, char **argv) MAIN_EXTERNALLY_VISIBLE;
int openssl_main(int argc UNUSED_PARAM, char **argv)
{
	const char *connect_arg = NULL;
	const char *servername = NULL;
	char *hostport;
	char *host;
	int port;
	int fd;
	int ret;
	mbedtls_entropy_context entropy;
	mbedtls_ctr_drbg_context ctr_drbg;
	mbedtls_ssl_context ssl;
	mbedtls_ssl_config conf;
	struct tls_fd tls_fd;

	if (!argv[1] || strcmp(argv[1], "s_client") != 0)
		bb_show_usage();

	argv += 2;
	while (*argv) {
		if (strcmp(*argv, "-connect") == 0 && argv[1]) {
			connect_arg = *++argv;
		} else if (strcmp(*argv, "-servername") == 0 && argv[1]) {
			servername = *++argv;
		} else if (strcmp(*argv, "-quiet") == 0
		 || strcmp(*argv, "-verify_return_error") == 0
		) {
			/* accepted and ignored */
		} else if ((strcmp(*argv, "-verify") == 0
		 || strcmp(*argv, "-verify_hostname") == 0
		 || strcmp(*argv, "-verify_ip") == 0) && argv[1]
		) {
			argv++;
		}
		argv++;
	}

	if (!connect_arg)
		bb_show_usage();

	hostport = xstrdup(connect_arg);
	split_host_port(hostport, &host, &port);
	if (!servername)
		servername = host;

	fd = create_and_connect_stream_or_die(host, port);
	tls_fd.fd = fd;

	mbedtls_entropy_init(&entropy);
	mbedtls_ctr_drbg_init(&ctr_drbg);
	mbedtls_ssl_init(&ssl);
	mbedtls_ssl_config_init(&conf);

	ret = mbedtls_ctr_drbg_seed(&ctr_drbg, mbedtls_entropy_func, &entropy,
			(const unsigned char *)"busybox-mbedtls", 16);
	if (ret != 0)
		tls_die(ret, "mbedtls_ctr_drbg_seed");

	ret = mbedtls_ssl_config_defaults(&conf,
			MBEDTLS_SSL_IS_CLIENT,
			MBEDTLS_SSL_TRANSPORT_STREAM,
			MBEDTLS_SSL_PRESET_DEFAULT);
	if (ret != 0)
		tls_die(ret, "mbedtls_ssl_config_defaults");

#if defined(MBEDTLS_SSL_PROTO_TLS1_2)
	mbedtls_ssl_conf_min_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
#endif
#if defined(MBEDTLS_SSL_PROTO_TLS1_3)
	mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_3);
#endif
	mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
	mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &ctr_drbg);

	ret = mbedtls_ssl_setup(&ssl, &conf);
	if (ret != 0)
		tls_die(ret, "mbedtls_ssl_setup");

	if (servername && !looks_like_ip_address(servername)) {
		ret = mbedtls_ssl_set_hostname(&ssl, servername);
		if (ret != 0)
			tls_die(ret, "mbedtls_ssl_set_hostname");
	}

	mbedtls_ssl_set_bio(&ssl, &tls_fd, fd_send, fd_recv, NULL);

	do {
		ret = mbedtls_ssl_handshake(&ssl);
	} while (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE);
	if (ret != 0)
		tls_die(ret, "mbedtls_ssl_handshake");

	ret = pump_tls(&ssl, fd);

	mbedtls_ssl_close_notify(&ssl);
	mbedtls_ssl_free(&ssl);
	mbedtls_ssl_config_free(&conf);
	mbedtls_ctr_drbg_free(&ctr_drbg);
	mbedtls_entropy_free(&entropy);
	close(fd);
	free(hostport);

	return ret;
}
EOF_MBEDTLS_OPENSSL
}

prepare_config() {
  local src_dir=$1
  local extra_ldlibs=${2:-}
  local config_path="$src_dir/.config"

  pushd "$src_dir" >/dev/null
  make distclean >/dev/null 2>&1 || true

  # Select the broadest BusyBox feature set first. The overrides below keep the
  # result as one static executable and remove debug/external-library bloat.
  if ! make allyesconfig >"$src_dir/allyesconfig.log" 2>&1; then
    cat "$src_dir/allyesconfig.log" >&2
    exit 1
  fi
  popd >/dev/null

  config_set "$config_path" CONFIG_STATIC y
  config_set "$config_path" CONFIG_PIE n
  config_set "$config_path" CONFIG_NOMMU n
  config_set "$config_path" CONFIG_BUILD_LIBBUSYBOX n
  config_set "$config_path" CONFIG_FEATURE_INDIVIDUAL n
  config_set "$config_path" CONFIG_FEATURE_SHARED_BUSYBOX n
  config_set "$config_path" CONFIG_DEBUG n
  config_set "$config_path" CONFIG_DEBUG_PESSIMIZE n
  config_set "$config_path" CONFIG_DEBUG_SANITIZE n
  config_set "$config_path" CONFIG_UNIT_TEST n
  config_set "$config_path" CONFIG_WERROR n
  config_set "$config_path" CONFIG_WARN_SIMPLE_MSG n
  config_set "$config_path" CONFIG_DMALLOC n
  config_set "$config_path" CONFIG_EFENCE n
  config_set "$config_path" CONFIG_NO_DEBUG_LIB n
  config_set "$config_path" CONFIG_FEATURE_VERBOSE_USAGE n
  config_set "$config_path" CONFIG_FEATURE_INSTALLER y
  config_set "$config_path" CONFIG_INSTALL_APPLET_SYMLINKS y
  config_set "$config_path" CONFIG_INSTALL_APPLET_HARDLINKS n
  config_set "$config_path" CONFIG_INSTALL_APPLET_SCRIPT_WRAPPERS n
  config_set "$config_path" CONFIG_FEATURE_CLEAN_UP n
  config_set "$config_path" CONFIG_FEATURE_SUID n
  config_set "$config_path" CONFIG_FEATURE_SUID_CONFIG n
  config_set "$config_path" CONFIG_FEATURE_SUID_CONFIG_QUIET n
  config_set "$config_path" CONFIG_FEATURE_EDITING_SAVEHISTORY n
  config_set "$config_path" CONFIG_FEATURE_REVERSE_SEARCH n
  config_set "$config_path" CONFIG_FEATURE_WTMP n
  config_set "$config_path" CONFIG_FEATURE_UTMP n
  # Do not require /etc/services for built-in well-known ports. BusyBox maps
  # wget's http/https/ftp defaults through bb_lookup_std_port(), which otherwise
  # tries to resolve service names at runtime and fails in minimal initramfses.
  config_set "$config_path" CONFIG_FEATURE_ETC_SERVICES n

  # These features pull in external libraries or external executables, which
  # works against the "single static BusyBox binary" goal.
  config_set "$config_path" CONFIG_PAM n
  config_set "$config_path" CONFIG_SELINUX n
  config_set "$config_path" CONFIG_ZSTD y
  config_set "$config_path" CONFIG_UNZSTD y
  config_set "$config_path" CONFIG_ZSTDCAT y
  config_set "$config_path" CONFIG_FEATURE_SEAMLESS_ZSTD y
  config_set "$config_path" CONFIG_EXTRA_LDLIBS "\"$extra_ldlibs\""

  if (( MBEDTLS_MODE )); then
    config_set "$config_path" CONFIG_FEATURE_WGET_OPENSSL y
    config_set "$config_path" CONFIG_FEATURE_WGET_HTTPS n
    config_set "$config_path" CONFIG_SSL_CLIENT n
    config_set "$config_path" CONFIG_SSL_SERVER n
    config_set "$config_path" CONFIG_TLS n
    config_set "$config_path" CONFIG_FEATURE_TLS_SHA1 n
    config_set "$config_path" CONFIG_FEATURE_PREFER_APPLETS y
    config_set "$config_path" CONFIG_BUSYBOX_EXEC_PATH '"/proc/self/exe"'
  else
    config_set "$config_path" CONFIG_FEATURE_WGET_OPENSSL n
  fi

  # Keep all applet symbols from allyesconfig. Only trim feature-level options
  # that are known to be unsuitable for small static initrd/live images.
  config_set "$config_path" CONFIG_LOCALE_SUPPORT n
  config_set "$config_path" CONFIG_UNICODE_SUPPORT n
  config_set "$config_path" CONFIG_FEDORA_COMPAT n
  config_set "$config_path" CONFIG_FEATURE_2_4_MODULES n
  config_set "$config_path" CONFIG_FEATURE_VI_REGEX_SEARCH n
  config_set "$config_path" CONFIG_FEATURE_MOUNT_NFS n
  config_set "$config_path" CONFIG_FEATURE_INETD_RPC n
  config_set "$config_path" CONFIG_EXTRA_COMPAT n
  config_set "$config_path" CONFIG_INCLUDE_SUSv2 n
  config_set "$config_path" CONFIG_IOCTL_HEX2STR_ERROR n

  pushd "$src_dir" >/dev/null
  # `yes` exits with SIGPIPE once oldconfig consumes enough input; temporarily
  # disable pipefail so a successful oldconfig run doesn't abort the script.
  set +o pipefail
  yes "" | make oldconfig >/dev/null
  set -o pipefail
  popd >/dev/null
}

patch_busybox_source() {
  local src_dir=$1
  local tc_c="$src_dir/networking/tc.c"
  local tmp="$tc_c.tmp"

  if grep -q "BUSYBOX_TC_CBQ_COMPAT" "$tc_c"; then
    return 0
  fi

  # BusyBox 1.38.0 tc still prints CBQ attributes, but newer linux UAPI
  # headers no longer ship the deprecated CBQ definitions. Add the historical
  # userspace structs back when the toolchain headers do not provide them.
  awk '
    { print }
    /#include <linux\/pkt_sched.h>/ && !inserted {
      print ""
      print "#ifndef TCA_CBQ_MAX"
      print "#define BUSYBOX_TC_CBQ_COMPAT 1"
      print "#define TC_CBQ_MAXPRIO 8"
      print "#define TC_CBQ_MAXLEVEL 8"
      print "#define TC_CBQ_DEF_EWMA 5"
      print "struct tc_cbq_lssopt {"
      print "\tunsigned char change;"
      print "\tunsigned char flags;"
      print "#define TCF_CBQ_LSS_BOUNDED 1"
      print "#define TCF_CBQ_LSS_ISOLATED 2"
      print "\tunsigned char ewma_log;"
      print "\tunsigned char level;"
      print "#define TCF_CBQ_LSS_FLAGS 1"
      print "#define TCF_CBQ_LSS_EWMA 2"
      print "#define TCF_CBQ_LSS_MAXIDLE 4"
      print "#define TCF_CBQ_LSS_MINIDLE 8"
      print "#define TCF_CBQ_LSS_OFFTIME 0x10"
      print "#define TCF_CBQ_LSS_AVPKT 0x20"
      print "\t__u32 maxidle;"
      print "\t__u32 minidle;"
      print "\t__u32 offtime;"
      print "\t__u32 avpkt;"
      print "};"
      print "struct tc_cbq_wrropt {"
      print "\tunsigned char flags;"
      print "\tunsigned char priority;"
      print "\tunsigned char cpriority;"
      print "\tunsigned char __reserved;"
      print "\t__u32 allot;"
      print "\t__u32 weight;"
      print "};"
      print "struct tc_cbq_ovl {"
      print "\tunsigned char strategy;"
      print "#define TC_CBQ_OVL_CLASSIC 0"
      print "#define TC_CBQ_OVL_DELAY 1"
      print "#define TC_CBQ_OVL_LOWPRIO 2"
      print "#define TC_CBQ_OVL_DROP 3"
      print "#define TC_CBQ_OVL_RCLASSIC 4"
      print "\tunsigned char priority2;"
      print "\t__u16 pad;"
      print "\t__u32 penalty;"
      print "};"
      print "struct tc_cbq_police {"
      print "\tunsigned char police;"
      print "\tunsigned char __res1;"
      print "\tunsigned short __res2;"
      print "};"
      print "struct tc_cbq_fopt {"
      print "\t__u32 split;"
      print "\t__u32 defmap;"
      print "\t__u32 defchange;"
      print "};"
      print "struct tc_cbq_xstats {"
      print "\t__u32 borrows;"
      print "\t__u32 overactions;"
      print "\t__s32 avgidle;"
      print "\t__s32 undertime;"
      print "};"
      print "enum {"
      print "\tTCA_CBQ_UNSPEC,"
      print "\tTCA_CBQ_LSSOPT,"
      print "\tTCA_CBQ_WRROPT,"
      print "\tTCA_CBQ_FOPT,"
      print "\tTCA_CBQ_OVL_STRATEGY,"
      print "\tTCA_CBQ_RATE,"
      print "\tTCA_CBQ_RTAB,"
      print "\tTCA_CBQ_POLICE,"
      print "\t__TCA_CBQ_MAX,"
      print "};"
      print "#define TCA_CBQ_MAX (__TCA_CBQ_MAX - 1)"
      print "#endif"
      inserted = 1
    }
  ' "$tc_c" >"$tmp"
  mv "$tmp" "$tc_c"
}

build_target() {
  local target=$1
  local output_name=$2
  local cc=$3
  local strip_tool=$4
  local src_dir="$BUILD_DIR/busybox-src-$target"
  local cflags="$SIZE_CFLAGS"
  local extra_ldlibs=""
  local mbedtls_ldlibs=""
  local zstd_ldlibs
  local ldflags

  require_tool "$cc"
  require_tool "$strip_tool"

  if [[ "$target" == "aarch64" && "$cc" == "aarch64-linux-musl-gcc" ]]; then
    cflags="$cflags -isystem $(prepare_aarch64_musl_uapi_overlay)"
  fi

  ldflags=$(resolve_static_ldflags "$target" "$cc")
  build_zstd_for_target "$target" "$cc" "$cflags" "$ldflags"
  zstd_ldlibs="$(zstd_ldlibs_for_target "$target")"
  extra_ldlibs="$zstd_ldlibs"
  cflags="$cflags -I$(zstd_source_dir "$target")/lib"

  if (( MBEDTLS_MODE )); then
    build_mbedtls_for_target "$target" "$cc" "$cflags" "$ldflags"
    mbedtls_ldlibs="$(mbedtls_ldlibs_for_target "$target")"
    extra_ldlibs="$extra_ldlibs $mbedtls_ldlibs"
    cflags="$cflags -I$MBEDTLS_SRC_DIR/include"
  fi

  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar -xf "$SRC_CACHE_DIR/$BUSYBOX_TARBALL" -C "$src_dir" --strip-components=1
  patch_busybox_source "$src_dir"
  patch_zstd_applet "$src_dir"
  if (( MBEDTLS_MODE )); then
    patch_mbedtls_openssl_applet "$src_dir"
  fi

  prepare_config "$src_dir" "$extra_ldlibs"

  echo
  echo "Building $output_name with $cc"
  pushd "$src_dir" >/dev/null
  make -j"$JOBS" \
    CC="$cc" \
    STRIP="$strip_tool" \
    HOSTCC=gcc \
    HOSTCXX=g++ \
    EXTRA_CFLAGS="$cflags" \
    EXTRA_LDFLAGS="$ldflags" \
    busybox
  "$strip_tool" -s busybox
  "$strip_tool" --remove-section=.eh_frame --remove-section=.eh_frame_hdr --remove-section=.note.gnu.property busybox 2>/dev/null || true
  popd >/dev/null

  install -Dm755 "$src_dir/busybox" "$ARTIFACT_DIR/$output_name"
  install -Dm755 "$src_dir/busybox" "$ROOT_DIR/$output_name"

  echo
  echo "Built static $output_name:"
  file "$ARTIFACT_DIR/$output_name"
  ls -lh "$ARTIFACT_DIR/$output_name"
  echo "ELF interpreter entries:"
  readelf -l "$ARTIFACT_DIR/$output_name" | grep -F INTERP || echo "  none"
  echo "Applet count:"
  local runner=()
  if [[ "$target" == "aarch64" ]]; then
    if have_tool qemu-aarch64; then
      runner=(qemu-aarch64 "$ARTIFACT_DIR/$output_name")
    elif have_tool qemu-aarch64-static; then
      runner=(qemu-aarch64-static "$ARTIFACT_DIR/$output_name")
    fi
  else
    runner=("$ARTIFACT_DIR/$output_name")
  fi

  if [[ ${#runner[@]} -gt 0 ]] && "${runner[@]}" --list >"$BUILD_DIR/${output_name}.applets" 2>/dev/null; then
    wc -l <"$BUILD_DIR/${output_name}.applets"
  else
    echo "  cannot execute on this host"
  fi
}

require_tool curl
require_tool tar
require_tool make
require_tool awk gawk
require_tool readelf binutils
require_tool bzip2
require_tool mktemp coreutils
require_tool gcc
require_tool g++ gcc
require_tool "$NATIVE_CC" musl
require_tool "$NATIVE_STRIP" binutils
if (( MBEDTLS_MODE )); then
  require_tool git
  require_tool cmake
fi

AARCH64_CC="$(select_aarch64_cc)"
AARCH64_STRIP="$(select_strip "$AARCH64_CC")"

if [[ "$AARCH64_STRIP" == aarch64-linux-gnu-strip ]]; then
  require_tool "$AARCH64_STRIP" aarch64-linux-gnu-binutils
else
  require_tool "$AARCH64_STRIP" binutils
fi

mkdir -p "$SRC_CACHE_DIR" "$ARTIFACT_DIR"
fetch "$BUSYBOX_URL" "$SRC_CACHE_DIR/$BUSYBOX_TARBALL"
fetch "$ZSTD_URL" "$SRC_CACHE_DIR/$ZSTD_TARBALL"
if (( MBEDTLS_MODE )); then
  prepare_mbedtls_source
fi

build_target native busybox "$NATIVE_CC" "$NATIVE_STRIP"
build_target aarch64 busybox_aarch64 "$AARCH64_CC" "$AARCH64_STRIP"
