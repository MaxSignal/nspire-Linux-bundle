#!/bin/sh
# Build the initrd of the OpenWrt variant: the BusyBox initrd (for its /init)
# carrying an OpenWrt root filesystem, which /init unpacks into the Linux
# image on the first boot, or into RAM when there is no image. The root
# filesystem is made by the official ImageBuilder of the at91/sam9x target
# (ARM926EJ-S) from the official packages, without the router ones.
# Needs the ImageBuilder's host tools: gawk, make, perl, python3, zstd...
# Input: $WORK/rootfs-base.list (build-rootfs.sh), $OUT/fastfetch
# Output: $OUT/openwrt.cpio.gz, $OUT/openwrt.version
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

D=$WORK/openwrt
IB=openwrt-imagebuilder-$OPENWRT_VERSION-at91-sam9x.Linux-x86_64.tar.zst
PROFILE=atmel_at91sam9g20ek	# any profile of the target: only its root filesystem is used
mkdir -p "$D"
if [ ! -f "$D/$IB" ]; then
	curl -fsSL -o "$D/$IB.part" "$OPENWRT_URL/$IB"
	mv "$D/$IB.part" "$D/$IB"
fi
curl -fsSL "$OPENWRT_URL/sha256sums" | grep " \*$IB\$" > "$D/sha256sums"
(cd "$D" && sha256sum -c sha256sums)

rm -rf "$D/ib"
mkdir -p "$D/ib/tmp"
tar --zstd -xf "$D/$IB" -C "$D/ib" --strip-components=1
rm -rf "$D/bin"
make -C "$D/ib" image PROFILE="$PROFILE" PACKAGES="$OPENWRT_PACKAGES" BIN_DIR="$D/bin"
ROOTFS=$D/bin/openwrt-$OPENWRT_VERSION-at91-sam9x-$PROFILE-rootfs.tar.gz
echo "OpenWrt packages:"
cut -d' ' -f1 "$D/bin/"*.manifest | tr '\n' ' '
echo

# The overlay, fastfetch (not packaged by OpenWrt) and the console colours
# of the minimal system
rm -rf "$D/overlay"
cp -r "$TOP/openwrt/overlay" "$D/overlay"
mkdir -p "$D/overlay/usr/bin" "$D/overlay/usr/sbin"
cp "$OUT/fastfetch" "$D/overlay/usr/bin/"
cp "$TOP/rootfs/overlay/usr/sbin/nspire-console" "$D/overlay/usr/sbin/"
python3 -I "$TOP/scripts/openwrt-rootfs.py" "$ROOTFS" "$D/rootfs.tar.gz" "$D/overlay" "$TOP/openwrt/remove"

GEN=${GEN_INIT_CPIO:-$OUT/gen_init_cpio}
[ -f "$WORK/rootfs-base.list" ] || { echo "run build-rootfs.sh first" >&2; exit 1; }
{
	cat "$WORK/rootfs-base.list"
	echo "dir /payload 0755 0 0"
	echo "file /payload/rootfs.tar.gz $D/rootfs.tar.gz 0644 0 0"
} > "$WORK/openwrt.list"
"$GEN" "$WORK/openwrt.list" | gzip -9 -n > "$OUT/openwrt.cpio.gz"
echo "$OPENWRT_VERSION" > "$OUT/openwrt.version"
echo "openwrt: $(wc -c < "$OUT/openwrt.cpio.gz") bytes, OpenWrt $OPENWRT_VERSION"
