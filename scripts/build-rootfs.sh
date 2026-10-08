#!/bin/sh
# Build a static BusyBox and pack the root filesystem as a gzipped cpio
# archive (an initramfs passed as initrd by the loader), with fastfetch.
# Input: $OUT/fastfetch (build-fastfetch.sh)
# Output: $OUT/rootfs.cpio.gz (with fastfetch), $OUT/rootfs-noff.cpio.gz
# (without), $OUT/rootfs*.min-kib (the space each needs in an image),
# $WORK/rootfs-base.list (for the OpenWrt initrd)
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

. scripts/musl-toolchain.sh

if [ ! -d "$WORK/busybox-$BUSYBOX_VERSION" ]; then
	curl -fsSL "$BUSYBOX_URL" | tar -xj -C "$WORK"
fi
BB=$WORK/busybox-build
rm -rf "$BB"
mkdir -p "$BB"
make -C "$WORK/busybox-$BUSYBOX_VERSION" O="$BB" allnoconfig >/dev/null
# Only what rootfs/busybox.config asks for
while IFS= read -r line; do
	case "$line" in
	'# CONFIG_'*' is not set') key=${line#\# }; key=${key%% *};;
	''|'#'*) continue;;
	*) key=${line%%=*};;
	esac
	sed -i -e "/^$key=/d" -e "/^# $key is not set/d" "$BB/.config"
	echo "$line" >> "$BB/.config"
done < "$TOP/rootfs/busybox.config"
yes "" | make -C "$BB" CROSS_COMPILE="$ROOTFS_CROSS_COMPILE" oldconfig >/dev/null
# Fail if an option did not stick (renamed, or unmet dependency)
grep "^CONFIG_" "$TOP/rootfs/busybox.config" | while IFS= read -r l; do
	grep -qxF "$l" "$BB/.config" || { echo "busybox option not applied: $l" >&2; exit 1; }
done
make -C "$BB" CROSS_COMPILE="$ROOTFS_CROSS_COMPILE" -j"$JOBS" busybox busybox.links

# gen_init_cpio from the kernel build, or build it from a kernel tree
GEN=${GEN_INIT_CPIO:-$OUT/gen_init_cpio}
[ -x "$GEN" ] || { echo "gen_init_cpio not found (run build-kernel.sh first)" >&2; exit 1; }

[ -f "$OUT/fastfetch" ] || { echo "run build-fastfetch.sh first" >&2; exit 1; }
# Reads the payload of a new image (OpenWrt)
"${ROOTFS_CROSS_COMPILE}gcc" -Os -static -Wall -Werror -s -o "$WORK/nspire-payload" \
	"$TOP/rootfs/tools/nspire-payload.c"
LIST=$WORK/rootfs-base.list
{
	cat "$TOP/rootfs/devices.list"
	echo "file /bin/busybox $BB/busybox 0755 0 0"
	echo "file /sbin/nspire-payload $WORK/nspire-payload 0755 0 0"
	# Overlay: directories first, then files (scripts keep their mode)
	(cd "$TOP/rootfs/overlay" && find . -mindepth 1 -type d | sort | sed 's|^\.||') |
		while read -r d; do
			grep -q "^dir $d " "$TOP/rootfs/devices.list" && continue
			mode=0755; [ "$d" = /root ] && mode=0700
			echo "dir $d $mode 0 0"
		done
	(cd "$TOP/rootfs/overlay" && find . -type f | sort | sed 's|^\.||') |
		while read -r f; do
			mode=0644; [ -x "$TOP/rootfs/overlay$f" ] && mode=0755
			echo "file $f $TOP/rootfs/overlay$f $mode 0 0"
		done
	grep '^/' "$BB/busybox.links" | grep -vx /bin/busybox |
		while read -r l; do echo "slink $l /bin/busybox 0777 0 0"; done
} > "$LIST"

# With fastfetch (rootfs) and without (rootfs-noff). /rootfs-kib tells /init
# the space the root filesystem needs in an image; package.sh puts it into
# the loader's config file too.
for v in rootfs rootfs-noff; do
	{
		cat "$LIST"
		[ $v = rootfs ] && echo "file /usr/bin/fastfetch $OUT/fastfetch 0755 0 0"
	} > "$WORK/$v.list"
	python3 -I "$TOP/scripts/rootfs-size.py" --cpio-list "$WORK/$v.list" > "$OUT/$v.min-kib"
	echo "file /rootfs-kib $OUT/$v.min-kib 0644 0 0" >> "$WORK/$v.list"
	"$GEN" "$WORK/$v.list" | gzip -9 -n > "$OUT/$v.cpio.gz"
	echo "$v: $(wc -c < "$OUT/$v.cpio.gz") bytes, $(cat "$OUT/$v.min-kib") KiB needed, busybox $BUSYBOX_VERSION"
done
