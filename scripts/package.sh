#!/bin/sh
# Assemble the files to copy to the calculator and zip them, one ZIP per
# variant. Everything goes to the calculator's "linux" folder; the minimal
# system and OpenWrt use different file names so that they can be installed
# side by side. Each comes with fastfetch, and without (-noff).
# Input: $OUT/{linuxloader2.tns,zImage,nspire-*.dtb,kernel.release} and
#        $OUT/{rootfs,rootfs-noff,openwrt,openwrt-noff}.{cpio.gz,min-kib},
#        $OUT/openwrt{,-noff}.tar.gz
# Output: $OUT/nspire-linux-<release>[-no-fastfetch].zip,
#         $OUT/nspire-openwrt-<version>-<release>[-no-fastfetch].zip
# Usage: package.sh [busybox|busybox-noff|openwrt|openwrt-noff]...
#        (default: the variants that were built)
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

REL=$(cat "$OUT/kernel.release")
# ZIP timestamps start in 1980
EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$TOP" log -1 --format=%ct 2>/dev/null || echo 315532800)}
if [ $# -eq 0 ]; then
	for v in busybox:rootfs busybox-noff:rootfs-noff openwrt:openwrt openwrt-noff:openwrt-noff; do
		[ -f "$OUT/${v#*:}.cpio.gz" ] && set -- "$@" "${v%%:*}"
	done
fi

for variant; do
	# The -noff variants leave fastfetch out; on the calculator, their
	# files have the same names
	case $variant in
	busybox|busybox-noff)
		NAME=nspire-linux-$REL SYSTEM=Linux PREFIX=linux SRC=rootfs
		INITRD=rootfs.cpio.gz IMAGE=rootfs.img.tns;;
	openwrt|openwrt-noff)
		NAME=nspire-openwrt-$(cat "$OUT/openwrt.version")-$REL SYSTEM=OpenWrt PREFIX=openwrt
		SRC=openwrt INITRD=openwrt.cpio.gz IMAGE=openwrt.img.tns;;
	*) echo "unknown variant $variant" >&2; exit 1;;
	esac
	case $variant in *-noff) NAME=$NAME-no-fastfetch SRC=$SRC-noff;; esac
	STAGE=$WORK/package/$NAME
	rm -rf "$STAGE"
	mkdir -p "$STAGE/linux"

	# Files sent to the calculator need the .tns extension
	cp "$OUT/linuxloader2.tns" "$STAGE/linux/"
	cp "$OUT/zImage" "$STAGE/linux/zImage.tns"
	cp "$OUT/$SRC.cpio.gz" "$STAGE/linux/$INITRD.tns"
	sed -e "s|@IMAGE@|$IMAGE|" -e "s|@MIN@|$(cat "$OUT/$SRC.min-kib")K|" \
		"$TOP/boot/rootimg.cfg" > "$STAGE/linux/$PREFIX.cfg.tns"
	# OpenWrt's root filesystem, written into the new image by the loader
	if [ -f "$OUT/$SRC.tar.gz" ]; then
		cp "$OUT/$SRC.tar.gz" "$STAGE/linux/openwrt.tar.gz.tns"
		cat >> "$STAGE/linux/$PREFIX.cfg.tns" <<CFG
# The root filesystem, written into the image when it is created
payload = /documents/linux/openwrt.tar.gz.tns
CFG
	fi
	for m in cx tp clp; do
		cp "$OUT/nspire-$m.dtb" "$STAGE/linux/nspire-$m.dtb.tns"
		sed -e "s|@SYSTEM@|$SYSTEM|" -e "s|@CFG@|$PREFIX.cfg.tns|" -e "s|@INITRD@|$INITRD.tns|" \
			"$TOP/boot/$m.ll2" > "$STAGE/linux/$PREFIX-$m.ll2.tns"
	done
	if grep -q @ "$STAGE"/linux/*.ll2.tns "$STAGE"/linux/*.cfg.tns; then
		echo "unreplaced placeholder in $NAME" >&2; exit 1
	fi
	# Same timestamps in every build
	find "$STAGE" -exec touch -h -d @"$EPOCH" {} +

	rm -f "$OUT/$NAME.zip"
	(cd "$STAGE" && find linux | LC_ALL=C sort | zip -q -X "$OUT/$NAME.zip" -@)
	(cd "$OUT" && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
	unzip -l "$OUT/$NAME.zip"
done
