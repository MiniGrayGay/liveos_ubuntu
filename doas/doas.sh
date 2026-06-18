#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-/root/kernel/doas/opendoas-6.8.2}"
OUT_DIR="$SRC_DIR/dist"

mkdir -p "$OUT_DIR"

build_one() {
    local platform="$1"
    local arch="$2"

    echo "==> Building doas for $platform"

    docker run --rm \
        --platform "$platform" \
        -v "$SRC_DIR":/src \
        -w /src \
        alpine:latest sh -euxc '
            apk add --no-cache build-base bison shadow-dev file binutils

            rm -f doas config.h config.mk *.o *.d parse.c y.tab.c
            find libopenbsd -name "*.o" -o -name "*.d" | xargs -r rm -f

            CFLAGS="-Os -ffunction-sections -fdata-sections" \
            ./configure

            make -B

            cc -static -s -Wl,--gc-sections \
              parse.o doas.o env.o \
              libopenbsd/errc.o libopenbsd/verrc.o \
              libopenbsd/progname.o libopenbsd/readpassphrase.o \
              libopenbsd/strtonum.o libopenbsd/execvpe.o \
              libopenbsd/closefrom.o shadow.o \
              -o doas \
              -lcrypt

            strip doas || true

            file doas
            readelf -d doas | grep NEEDED && exit 1 || true
        '

    cp "$SRC_DIR/doas" "$OUT_DIR/doas-$arch"
    chmod 755 "$OUT_DIR/doas-$arch"

    echo "==> Output: $OUT_DIR/doas-$arch"
    file "$OUT_DIR/doas-$arch"
    ls -lh "$OUT_DIR/doas-$arch"
}

build_one linux/amd64 amd64
build_one linux/arm64 arm64

echo
echo "Done:"
ls -lh "$OUT_DIR"/doas-*