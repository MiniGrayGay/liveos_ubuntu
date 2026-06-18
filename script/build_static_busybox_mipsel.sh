#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/busybox-mipsel-static"
SRC_CACHE_DIR="$BUILD_DIR/src"
TOOLCHAIN_CACHE_DIR="$BUILD_DIR/toolchain"
TOOLCHAIN_EXTRACT_DIR="$TOOLCHAIN_CACHE_DIR/extracted"
ARTIFACT_DIR="$BUILD_DIR/artifacts"

BUSYBOX_VER="${BUSYBOX_VER:-1.38.0}"
BUSYBOX_TARBALL="busybox-${BUSYBOX_VER}.tar.bz2"
BUSYBOX_URL="${BUSYBOX_URL:-https://busybox.net/downloads/${BUSYBOX_TARBALL}}"

ZSTD_VER="${ZSTD_VER:-1.5.7}"
ZSTD_TARBALL="zstd-${ZSTD_VER}.tar.gz"
ZSTD_URL="${ZSTD_URL:-https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/${ZSTD_TARBALL}}"

OPENWRT_RELEASE="${OPENWRT_RELEASE:-24.10.7}"
OPENWRT_TARGET="${OPENWRT_TARGET:-ramips/mt7621}"
OPENWRT_TOOLCHAIN_TARBALL="${OPENWRT_TOOLCHAIN_TARBALL:-openwrt-toolchain-24.10.7-ramips-mt7621_gcc-13.3.0_musl.Linux-x86_64.tar.zst}"
OPENWRT_TOOLCHAIN_SHA256="${OPENWRT_TOOLCHAIN_SHA256:-2dc6f4503ead1a4e925f5eb55de8b97d2caaa953d3de2334403fddb914a7e746}"
OPENWRT_TOOLCHAIN_URL="${OPENWRT_TOOLCHAIN_URL:-https://downloads.openwrt.org/releases/${OPENWRT_RELEASE}/targets/${OPENWRT_TARGET}/${OPENWRT_TOOLCHAIN_TARBALL}}"

OUTPUT_NAME="${OUTPUT_NAME:-busybox_mipsel_mt7621}"
UPX_OUTPUT_NAME="${UPX_OUTPUT_NAME:-busybox_mipsel_mt7621_upx}"
JOBS="${JOBS:-$(nproc)}"
HELP_TIMEOUT="${HELP_TIMEOUT:-5}"
MIN_APPLETS="${MIN_APPLETS:-300}"
USE_LTO="${USE_LTO:-1}"

MIPS_TUNE_CFLAGS="${MIPS_TUNE_CFLAGS:--mips32r2 -mtune=24kc -msoft-float}"
SIZE_CFLAGS="${SIZE_CFLAGS:--Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables -fmerge-all-constants}"
SIZE_LDFLAGS="${SIZE_LDFLAGS:--static -Wl,--gc-sections -Wl,--sort-common -s}"
UPX_FLAGS="${UPX_FLAGS:---best --lzma}"

have_tool() {
  command -v "$1" >/dev/null 2>&1
}

require_tool() {
  local tool=$1

  if ! have_tool "$tool"; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

fetch() {
  local url=$1
  local dest=$2

  if [[ -f "$dest" ]]; then
    return 0
  fi

  echo "Downloading $url" >&2
  curl -fL --retry 3 --retry-delay 2 -o "$dest.tmp" "$url"
  mv "$dest.tmp" "$dest"
}

verify_sha256() {
  local file=$1
  local expected=$2
  local actual

  if [[ -z "$expected" ]]; then
    return 0
  fi

  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "SHA256 mismatch for $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

first_matching_path() {
  local root=$1
  shift
  local -a matches=()

  mapfile -t matches < <(find "$root" \( -type f -o -type l \) "$@" 2>/dev/null | sort)
  if [[ "${#matches[@]}" -gt 0 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  return 1
}

find_prefixed_tool() {
  local cc=$1
  local suffix=$2
  local prefix candidate

  if [[ "$cc" == *gcc ]]; then
    prefix="${cc%gcc}"
    candidate="${prefix}${suffix}"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  candidate="$(dirname "$cc")/$(basename "$cc" gcc)${suffix}"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if have_tool "mipsel-openwrt-linux-musl-${suffix}"; then
    command -v "mipsel-openwrt-linux-musl-${suffix}"
    return 0
  fi

  if have_tool "mipsel-linux-musl-${suffix}"; then
    command -v "mipsel-linux-musl-${suffix}"
    return 0
  fi

  return 1
}

compiler_prefix_for_cc() {
  local cc=$1

  if [[ "$cc" == *gcc ]]; then
    printf '%s\n' "${cc%gcc}"
  else
    printf '%s\n' ""
  fi
}

select_mipsel_cc() {
  local tarball="$TOOLCHAIN_CACHE_DIR/$OPENWRT_TOOLCHAIN_TARBALL"
  local cc

  if [[ -n "${MIPSEL_CC:-}" ]]; then
    require_tool "$MIPSEL_CC"
    command -v "$MIPSEL_CC"
    return 0
  fi

  if have_tool mipsel-openwrt-linux-musl-gcc; then
    command -v mipsel-openwrt-linux-musl-gcc
    return 0
  fi

  if have_tool mipsel-linux-musl-gcc; then
    command -v mipsel-linux-musl-gcc
    return 0
  fi

  mkdir -p "$TOOLCHAIN_CACHE_DIR" "$TOOLCHAIN_EXTRACT_DIR"
  fetch "$OPENWRT_TOOLCHAIN_URL" "$tarball"
  verify_sha256 "$tarball" "$OPENWRT_TOOLCHAIN_SHA256"

  if ! cc="$(first_matching_path "$TOOLCHAIN_EXTRACT_DIR" -name mipsel-openwrt-linux-musl-gcc -perm -0100)"; then
    echo "Extracting $tarball" >&2
    rm -rf "$TOOLCHAIN_EXTRACT_DIR"
    mkdir -p "$TOOLCHAIN_EXTRACT_DIR"
    tar --zstd -xf "$tarball" -C "$TOOLCHAIN_EXTRACT_DIR"
    cc="$(first_matching_path "$TOOLCHAIN_EXTRACT_DIR" -name mipsel-openwrt-linux-musl-gcc -perm -0100)"
  fi

  printf '%s\n' "$cc"
}

configure_toolchain_env() {
  local cc=$1
  local bin_dir top_dir

  bin_dir="$(cd "$(dirname "$cc")" && pwd)"
  top_dir="$bin_dir"
  while [[ "$top_dir" != "/" && "$top_dir" != "." && "$(basename "$top_dir")" != staging_dir ]]; do
    top_dir="$(dirname "$top_dir")"
  done
  if [[ "$(basename "$top_dir")" == staging_dir ]]; then
    export STAGING_DIR="$top_dir"
  elif [[ -z "${STAGING_DIR:-}" ]]; then
    STAGING_DIR="$(dirname "$bin_dir")"
    export STAGING_DIR
  fi
  export PATH="$bin_dir:$PATH"
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

patch_busybox_source() {
  local src_dir=$1
  local tc_c="$src_dir/networking/tc.c"
  local tmp="$tc_c.tmp"

  if [[ ! -f "$tc_c" ]] || grep -q "BUSYBOX_TC_CBQ_COMPAT" "$tc_c"; then
    return 0
  fi

  # BusyBox 1.38.0 still references old CBQ UAPI definitions that are absent
  # from newer toolchains. Keep tc enabled by restoring the userspace structs.
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

zstd_source_dir() {
  printf '%s\n' "$BUILD_DIR/zstd-src-mipsel"
}

zstd_ldlibs() {
  local src_dir

  src_dir="$(zstd_source_dir)"
  printf '%s\n' "-L$src_dir/lib -lzstd"
}

build_zstd_library() {
  local cc=$1
  local cflags=$2
  local ldflags=$3
  local src_dir
  local ar_tool
  local ranlib_tool

  src_dir="$(zstd_source_dir)"
  ar_tool="$(find_prefixed_tool "$cc" gcc-ar || find_prefixed_tool "$cc" ar || command -v ar)"
  ranlib_tool="$(find_prefixed_tool "$cc" gcc-ranlib || find_prefixed_tool "$cc" ranlib || command -v ranlib)"

  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar -xf "$SRC_CACHE_DIR/$ZSTD_TARBALL" -C "$src_dir" --strip-components=1

  echo
  echo "Building zstd $ZSTD_VER decompressor library for mipsel with $cc"
  make -C "$src_dir/lib" -j"$JOBS" \
    CC="$cc" \
    AR="$ar_tool" \
    RANLIB="$ranlib_tool" \
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

prepare_config() {
  local src_dir=$1
  local extra_ldlibs=${2:-}
  local config_path="$src_dir/.config"
  local had_pipefail=0

  pushd "$src_dir" >/dev/null
  make distclean >/dev/null 2>&1 || true
  make HOSTCC=gcc HOSTCXX=g++ allyesconfig >"$src_dir/allyesconfig.log" 2>&1 || {
    cat "$src_dir/allyesconfig.log" >&2
    exit 1
  }
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
  config_set "$config_path" CONFIG_FEATURE_COMPRESS_USAGE y
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
  config_set "$config_path" CONFIG_FEATURE_ETC_SERVICES n

  config_set "$config_path" CONFIG_PAM n
  config_set "$config_path" CONFIG_SELINUX n
  config_set "$config_path" CONFIG_FEATURE_WGET_OPENSSL n
  config_set "$config_path" CONFIG_ZSTD y
  config_set "$config_path" CONFIG_UNZSTD y
  config_set "$config_path" CONFIG_ZSTDCAT y
  config_set "$config_path" CONFIG_FEATURE_SEAMLESS_ZSTD y
  config_set "$config_path" CONFIG_EXTRA_LDLIBS "\"$extra_ldlibs\""
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
  if [[ -o pipefail ]]; then
    had_pipefail=1
  fi
  set +o pipefail
  yes "" | make HOSTCC=gcc HOSTCXX=g++ oldconfig >/dev/null
  if (( had_pipefail )); then
    set -o pipefail
  fi
  popd >/dev/null
}

static_link_works() {
  local cc=$1
  local cflags=$2
  local ldflags=$3
  local test_dir=$4
  local test_c="$test_dir/conftest.c"
  local test_bin="$test_dir/conftest"

  printf 'int main(void) { return 0; }\n' >"$test_c"

  # cflags/ldflags are shell-style flag lists by design.
  # shellcheck disable=SC2086
  "$cc" $cflags $ldflags "$test_c" -o "$test_bin" >/dev/null 2>&1
}

validate_static_link() {
  local cc=$1
  local cflags=$2
  local ldflags=$3
  local test_dir

  test_dir="$(mktemp -d "${TMPDIR:-/tmp}/busybox-mipsel-link.XXXXXX")"
  if ! static_link_works "$cc" "$cflags" "$ldflags" "$test_dir"; then
    rm -rf "$test_dir"
    echo "$cc cannot create a static mipsel executable with the configured flags" >&2
    exit 1
  fi
  rm -rf "$test_dir"
}

print_binary_info() {
  local bin=$1

  file "$bin"
  ls -lh "$bin"
  echo "ELF interpreter entries:"
  readelf -l "$bin" | grep -F INTERP || echo "  none"
  echo "MIPS ABI attributes:"
  readelf -A "$bin" | sed -n '1,25p'
}

validate_binary() {
  local bin=$1
  local label=$2
  local qemu_mipsel="${QEMU_MIPSEL:-$(command -v qemu-mipsel)}"
  local applet_list="$BUILD_DIR/${label}.applets"
  local failures="$BUILD_DIR/${label}.help-failures"
  local tmp_root tmp_out applet status count

  if [[ "$qemu_mipsel" != /* ]]; then
    qemu_mipsel="$(command -v "$qemu_mipsel")"
  fi

  echo
  echo "Validating $label with qemu-mipsel"
  "$qemu_mipsel" "$bin" --help >/dev/null
  "$qemu_mipsel" "$bin" --list >"$applet_list"
  count="$(wc -l <"$applet_list")"
  echo "Applet count: $count"
  if (( count < MIN_APPLETS )); then
    echo "Applet count $count is below MIN_APPLETS=$MIN_APPLETS" >&2
    exit 1
  fi

  : >"$failures"
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/busybox-mipsel-help.XXXXXX")"
  while IFS= read -r applet; do
    [[ -n "$applet" ]] || continue
    set +e
    timeout "$HELP_TIMEOUT" "$qemu_mipsel" "$bin" "$applet" --help >"$tmp_out" 2>&1
    status=$?
    set -e
    if [[ "$status" != 0 && "$status" != 1 && "$status" != 2 ]]; then
      printf '%s exit=%s\n' "$applet" "$status" >>"$failures"
      continue
    fi
    if grep -Eiq 'applet not found|segmentation fault|invalid elf|error while loading|no such file or directory' "$tmp_out"; then
      printf '%s output-failed\n' "$applet" >>"$failures"
    fi
  done <"$applet_list"
  rm -f "$tmp_out"

  if [[ -s "$failures" ]]; then
    echo "Applet help validation failed:" >&2
    cat "$failures" >&2
    exit 1
  fi
  echo "All applets respond to --help under qemu-mipsel"

  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/busybox-mipsel-smoke.XXXXXX")"
  "$qemu_mipsel" "$bin" sh -c 'echo shell-ok' | grep -q '^shell-ok$'
  "$qemu_mipsel" "$bin" printf 'alpha\nbeta\n' >"$tmp_root/sample.txt"
  "$qemu_mipsel" "$bin" grep -q beta "$tmp_root/sample.txt"
  [[ "$("$qemu_mipsel" "$bin" awk 'END { print NR }' "$tmp_root/sample.txt")" == 2 ]]
  [[ "$("$qemu_mipsel" "$bin" sed -n '1p' "$tmp_root/sample.txt")" == alpha ]]
  "$qemu_mipsel" "$bin" mkdir -p "$tmp_root/dir"
  "$qemu_mipsel" "$bin" cp "$tmp_root/sample.txt" "$tmp_root/dir/copy.txt"
  "$qemu_mipsel" "$bin" tar -cf "$tmp_root/pack.tar" -C "$tmp_root" dir/copy.txt
  "$qemu_mipsel" "$bin" tar -tf "$tmp_root/pack.tar" | "$qemu_mipsel" "$bin" grep -q dir/copy.txt
  zstd -q -f "$tmp_root/pack.tar" -o "$tmp_root/pack.tar.zst"
  "$qemu_mipsel" "$bin" mkdir -p "$tmp_root/unpack-zst"
  env PATH=/no-such-path "$qemu_mipsel" "$bin" tar -xf "$tmp_root/pack.tar.zst" -C "$tmp_root/unpack-zst"
  "$qemu_mipsel" "$bin" cmp -s "$tmp_root/sample.txt" "$tmp_root/unpack-zst/dir/copy.txt"
  env PATH=/no-such-path "$qemu_mipsel" "$bin" zstdcat "$tmp_root/pack.tar.zst" >"$tmp_root/pack-zstdcat.tar"
  "$qemu_mipsel" "$bin" tar -tf "$tmp_root/pack-zstdcat.tar" | "$qemu_mipsel" "$bin" grep -q dir/copy.txt
  [[ "$("$qemu_mipsel" "$bin" dd if=/dev/zero bs=16 count=1 2>/dev/null | "$qemu_mipsel" "$bin" wc -c | tr -d ' ')" == 16 ]]
  "$qemu_mipsel" "$bin" ln -s sample.txt "$tmp_root/link.txt"
  [[ "$("$qemu_mipsel" "$bin" readlink "$tmp_root/link.txt")" == sample.txt ]]
  rm -rf "$tmp_root"
  echo "Smoke test passed under qemu-mipsel"
}

build_busybox() {
  local cc=$1
  local strip_tool=$2
  local src_dir="$BUILD_DIR/busybox-src-mipsel"
  local prefix ar_tool nm_tool ranlib_tool
  local cflags="$MIPS_TUNE_CFLAGS $SIZE_CFLAGS"
  local ldflags="$SIZE_LDFLAGS"
  local extra_ldlibs

  if [[ "$USE_LTO" == 1 ]]; then
    cflags="$cflags -flto=auto"
    ldflags="$ldflags -flto=auto"
  fi

  validate_static_link "$cc" "$cflags" "$ldflags"
  build_zstd_library "$cc" "$cflags" "$ldflags"
  extra_ldlibs="$(zstd_ldlibs)"
  cflags="$cflags -I$(zstd_source_dir)/lib"

  prefix="$(compiler_prefix_for_cc "$cc")"
  ar_tool="$(find_prefixed_tool "$cc" gcc-ar || find_prefixed_tool "$cc" ar || command -v ar)"
  nm_tool="$(find_prefixed_tool "$cc" gcc-nm || find_prefixed_tool "$cc" nm || command -v nm)"
  ranlib_tool="$(find_prefixed_tool "$cc" gcc-ranlib || find_prefixed_tool "$cc" ranlib || command -v ranlib)"

  rm -rf "$src_dir"
  mkdir -p "$src_dir"
  tar -xf "$SRC_CACHE_DIR/$BUSYBOX_TARBALL" -C "$src_dir" --strip-components=1
  patch_busybox_source "$src_dir"
  patch_zstd_applet "$src_dir"
  prepare_config "$src_dir" "$extra_ldlibs"

  echo
  echo "Building $OUTPUT_NAME with $cc"
  pushd "$src_dir" >/dev/null
  # cflags/ldflags are shell-style flag lists by design.
  # shellcheck disable=SC2086
  make -j"$JOBS" \
    CC="$cc" \
    CROSS_COMPILE="$prefix" \
    AR="$ar_tool" \
    NM="$nm_tool" \
    RANLIB="$ranlib_tool" \
    STRIP="$strip_tool" \
    HOSTCC=gcc \
    HOSTCXX=g++ \
    EXTRA_CFLAGS="$cflags" \
    EXTRA_LDFLAGS="$ldflags" \
    busybox
  "$strip_tool" -s busybox
  "$strip_tool" --remove-section=.eh_frame --remove-section=.eh_frame_hdr --remove-section=.note.gnu.property busybox 2>/dev/null || true
  popd >/dev/null

  install -Dm755 "$src_dir/busybox" "$ARTIFACT_DIR/$OUTPUT_NAME"
  install -Dm755 "$src_dir/busybox" "$ROOT_DIR/$OUTPUT_NAME"
}

compress_with_upx() {
  local input=$1
  local output=$2

  cp "$input" "$output"
  chmod 0755 "$output"
  # UPX_FLAGS is a shell-style flag list by design.
  # shellcheck disable=SC2086
  upx $UPX_FLAGS "$output"
}

main() {
  local cc strip_tool raw_bin upx_bin

  require_tool curl
  require_tool tar
  require_tool zstd
  require_tool make
  require_tool awk
  require_tool gcc
  require_tool qemu-mipsel
  require_tool timeout
  require_tool file
  require_tool readelf
  require_tool sha256sum
  require_tool upx

  mkdir -p "$SRC_CACHE_DIR" "$ARTIFACT_DIR"
  fetch "$BUSYBOX_URL" "$SRC_CACHE_DIR/$BUSYBOX_TARBALL"
  fetch "$ZSTD_URL" "$SRC_CACHE_DIR/$ZSTD_TARBALL"

  cc="$(select_mipsel_cc)"
  configure_toolchain_env "$cc"
  strip_tool="${MIPSEL_STRIP:-$(find_prefixed_tool "$cc" strip || true)}"
  if [[ -z "$strip_tool" ]]; then
    echo "Unable to find mipsel strip tool for $cc" >&2
    exit 1
  fi

  build_busybox "$cc" "$strip_tool"

  raw_bin="$ARTIFACT_DIR/$OUTPUT_NAME"
  echo
  echo "Built static mipsel BusyBox:"
  print_binary_info "$raw_bin"
  validate_binary "$raw_bin" "$OUTPUT_NAME"

  upx_bin="$ARTIFACT_DIR/$UPX_OUTPUT_NAME"
  echo
  echo "Compressing validated binary with upx: $UPX_FLAGS"
  compress_with_upx "$raw_bin" "$upx_bin"
  install -Dm755 "$upx_bin" "$ROOT_DIR/$UPX_OUTPUT_NAME"

  echo
  echo "Built UPX-compressed mipsel BusyBox:"
  print_binary_info "$upx_bin"
  validate_binary "$upx_bin" "$UPX_OUTPUT_NAME"

  echo
  echo "Artifacts:"
  ls -lh "$raw_bin" "$upx_bin" "$ROOT_DIR/$OUTPUT_NAME" "$ROOT_DIR/$UPX_OUTPUT_NAME"
}

main "$@"
