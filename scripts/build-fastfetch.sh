#!/bin/sh
# Build fastfetch as a static binary (ARMv5, musl) for both root filesystems,
# without the optional libraries (none of them is on the calculator).
# Input: $OUT/kernel-headers (build-kernel.sh)
# Output: $OUT/fastfetch
set -eu
cd "$(dirname "$0")/.."
. scripts/versions.sh
. scripts/musl-toolchain.sh

[ -d "$OUT/kernel-headers/include" ] || { echo "run build-kernel.sh first" >&2; exit 1; }
SRC=$WORK/fastfetch-$FASTFETCH_VERSION
if [ ! -d "$SRC" ]; then
	curl -fsSL -o "$WORK/fastfetch.tar.gz" "$FASTFETCH_URL"
	echo "$FASTFETCH_SHA256  $WORK/fastfetch.tar.gz" | sha256sum -c
	mkdir -p "$SRC"
	tar -xzf "$WORK/fastfetch.tar.gz" -C "$SRC" --strip-components=1
	rm "$WORK/fastfetch.tar.gz"
fi

off=
for o in VULKAN WAYLAND XCB_RANDR XRANDR DRM VADRM VAX11 VDPAU GIO DCONF EET DBUS \
	SQLITE3 RPM EGL GLX OPENCL FREETYPE PULSE DDCUTIL ELF IMAGE_LOGO IMAGEMAGICK7 \
	IMAGEMAGICK6 SIXEL CHAFA ZLIB LUA QUICKJS LIBZFS; do
	off="$off -DENABLE_$o=OFF"
done
B=$WORK/fastfetch-build
rm -rf "$B"
cmake -S "$SRC" -B "$B" -G Ninja -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
	-DCMAKE_C_COMPILER="${ROOTFS_CROSS_COMPILE}gcc" \
	-DCMAKE_C_FLAGS="-isystem $OUT/kernel-headers/include" \
	-DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_BUILD_TYPE=MinSizeRel $off \
	-DBUILD_FLASHFETCH=OFF -DIS_MUSL=ON -DSET_TWEAK=OFF -DINSTALL_LICENSE=OFF
ninja -C "$B" fastfetch
"${ROOTFS_CROSS_COMPILE}strip" -o "$OUT/fastfetch" "$B/fastfetch"
echo "fastfetch $FASTFETCH_VERSION: $(wc -c < "$OUT/fastfetch") bytes"
