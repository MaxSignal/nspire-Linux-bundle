#!/bin/sh
# Assemble the files to copy to the calculator and zip them, one ZIP per
# variant. Everything goes to the calculator's "linux" folder; the two
# variants use different file names so that they can be installed side by
# side.
# Input: $OUT/{linuxloader2.tns,zImage,nspire-*.dtb,kernel.release} and
#        $OUT/rootfs.cpio.gz (busybox) or $OUT/openwrt.cpio.gz (openwrt)
# Output: $OUT/nspire-linux-<release>.zip, $OUT/nspire-openwrt-<version>-<release>.zip
# Usage: package.sh [busybox|openwrt]...   (default: the variants that were built)
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

REL=$(cat "$OUT/kernel.release")
# ZIP timestamps start in 1980
EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$TOP" log -1 --format=%ct 2>/dev/null || echo 315532800)}
if [ $# -eq 0 ]; then
	[ -f "$OUT/rootfs.cpio.gz" ] && set -- "$@" busybox
	[ -f "$OUT/openwrt.cpio.gz" ] && set -- "$@" openwrt
fi

for variant; do
	case $variant in
	busybox)
		NAME=nspire-linux-$REL SYSTEM=Linux PREFIX=linux
		INITRD=rootfs.cpio.gz IMAGE=rootfs.img.tns;;
	openwrt)
		NAME=nspire-openwrt-$(cat "$OUT/openwrt.version")-$REL SYSTEM=OpenWrt PREFIX=openwrt
		INITRD=openwrt.cpio.gz IMAGE=openwrt.img.tns;;
	*) echo "unknown variant $variant" >&2; exit 1;;
	esac
	STAGE=$WORK/package/$NAME
	rm -rf "$STAGE"
	mkdir -p "$STAGE/linux"

	# Files sent to the calculator need the .tns extension
	cp "$OUT/linuxloader2.tns" "$STAGE/linux/"
	cp "$OUT/zImage" "$STAGE/linux/zImage.tns"
	cp "$OUT/$INITRD" "$STAGE/linux/$INITRD.tns"
	sed "s|@IMAGE@|$IMAGE|" "$TOP/boot/rootimg.cfg" > "$STAGE/linux/$PREFIX.cfg.tns"
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
