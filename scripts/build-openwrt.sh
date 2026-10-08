#!/bin/sh
# Build the OpenWrt variant: its root filesystem archive, which the loader
# writes into a new Linux image (too large for the initrd: the loader gets
# about 4 MB of RAM on a Touchpad, the kernel included), and the BusyBox
# initrd, whose /init unpacks it into the image on the first boot, or into
# RAM when the image is too small for it. The root
# filesystem is made by the official ImageBuilder of the at91/sam9x target
# (ARM926EJ-S) from the official packages, without the router ones.
# Needs the ImageBuilder's host tools: gawk, make, perl, python3, zstd...
# Input: $WORK/rootfs-base.list (build-rootfs.sh), $OUT/fastfetch
# Output: $OUT/openwrt{,-noff}.{cpio.gz,tar.gz,min-kib} (with fastfetch and
# without), $OUT/openwrt.version
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

# The overlay and the console colours of the minimal system, with
# fastfetch (not packaged by OpenWrt: openwrt) and without (openwrt-noff)
GEN=${GEN_INIT_CPIO:-$OUT/gen_init_cpio}
[ -f "$WORK/rootfs-base.list" ] || { echo "run build-rootfs.sh first" >&2; exit 1; }
for v in openwrt openwrt-noff; do
	rm -rf "$D/overlay"
	cp -r "$TOP/openwrt/overlay" "$D/overlay"
	mkdir -p "$D/overlay/usr/bin" "$D/overlay/usr/sbin"
	cp "$TOP/rootfs/overlay/usr/sbin/nspire-console" "$D/overlay/usr/sbin/"
	[ $v = openwrt ] && cp "$OUT/fastfetch" "$D/overlay/usr/bin/"
	python3 -I "$TOP/scripts/openwrt-rootfs.py" "$ROOTFS" "$D/$v.tar.gz" "$D/overlay" \
		"$TOP/openwrt/remove"
	python3 -I "$TOP/scripts/rootfs-size.py" --tar "$D/$v.tar.gz" > "$OUT/$v.min-kib"
	# The archive goes to the calculator as a file of its own, which the
	# loader writes into the new image: the initrd only says its name
	echo openwrt.tar.gz > "$WORK/payload-name"
	{
		cat "$WORK/rootfs-base.list"
		echo "file /payload-name $WORK/payload-name 0644 0 0"
		echo "file /rootfs-kib $OUT/$v.min-kib 0644 0 0"
	} > "$WORK/$v.list"
	"$GEN" "$WORK/$v.list" | gzip -9 -n > "$OUT/$v.cpio.gz"
	cp "$D/$v.tar.gz" "$OUT/$v.tar.gz"
	echo "$v: initrd $(wc -c < "$OUT/$v.cpio.gz") bytes, root filesystem $(wc -c < "$OUT/$v.tar.gz") bytes, $(cat "$OUT/$v.min-kib") KiB needed, OpenWrt $OPENWRT_VERSION"
done
echo "$OPENWRT_VERSION" > "$OUT/openwrt.version"
