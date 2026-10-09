#!/bin/sh
# Build a static BusyBox and pack the root filesystem as a gzipped cpio
# archive (an initramfs passed as initrd by the loader), with fastfetch.
# Input: $OUT/fastfetch (build-fastfetch.sh), $OUT/kernel-headers
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
# Only what rootfs/busybox.config asks for (and rootfs/debug/busybox.config
# in a debug build)
BBCONFIGS=$TOP/rootfs/busybox.config
[ "$DEBUG" = 1 ] && BBCONFIGS="$BBCONFIGS $TOP/rootfs/debug/busybox.config"
# shellcheck disable=SC2086
cat $BBCONFIGS | while IFS= read -r line; do
	case "$line" in
	'# CONFIG_'*' is not set') key=${line#\# }; key=${key%% *};;
	''|'#'*) continue;;
	*) key=${line%%=*};;
	esac
	sed -i -e "/^$key=/d" -e "/^# $key is not set/d" "$BB/.config"
	echo "$line" >> "$BB/.config"
done
yes "" | make -C "$BB" CROSS_COMPILE="$ROOTFS_CROSS_COMPILE" oldconfig >/dev/null
# Fail if an option did not stick (renamed, or unmet dependency)
# shellcheck disable=SC2086
grep -h "^CONFIG_" $BBCONFIGS | while IFS= read -r l; do
	grep -qxF "$l" "$BB/.config" || { echo "busybox option not applied: $l" >&2; exit 1; }
done
make -C "$BB" CROSS_COMPILE="$ROOTFS_CROSS_COMPILE" -j"$JOBS" busybox busybox.links

# gen_init_cpio from the kernel build, or build it from a kernel tree
GEN=${GEN_INIT_CPIO:-$OUT/gen_init_cpio}
[ -x "$GEN" ] || { echo "gen_init_cpio not found (run build-kernel.sh first)" >&2; exit 1; }

[ -f "$OUT/fastfetch" ] || { echo "run build-fastfetch.sh first" >&2; exit 1; }
# nspire-payload reads the payload of a new image (OpenWrt); in a debug
# build, nspire-nandinfo / nspire-nandraw / nspire-nanddma show the layout
# of the TI-Nspire OS filesystem and try the NAND controller
TOOLS="rootfs/tools/nspire-payload"
[ "$DEBUG" = 1 ] && TOOLS="$TOOLS rootfs/debug/tools/nspire-nandinfo rootfs/debug/tools/nspire-nandraw rootfs/debug/tools/nspire-nanddma"
for t in $TOOLS; do
	"${ROOTFS_CROSS_COMPILE}gcc" -Os -static -Wall -Werror -s \
		-isystem "$OUT/kernel-headers/include" -o "$WORK/${t##*/}" "$TOP/$t.c"
done
OVERLAYS=$TOP/rootfs/overlay
[ "$DEBUG" = 1 ] && OVERLAYS="$OVERLAYS $TOP/rootfs/debug/overlay"
LIST=$WORK/rootfs-base.list
{
	cat "$TOP/rootfs/devices.list"
	echo "file /bin/busybox $BB/busybox 0755 0 0"
	for t in $TOOLS; do
		echo "file /sbin/${t##*/} $WORK/${t##*/} 0755 0 0"
	done
	# Overlays: directories first, then files (scripts keep their mode)
	for o in $OVERLAYS; do
		(cd "$o" && find . -mindepth 1 -type d | sed 's|^\.||')
	done | sort -u | while read -r d; do
		grep -q "^dir $d " "$TOP/rootfs/devices.list" && continue
		mode=0755; [ "$d" = /root ] && mode=0700
		echo "dir $d $mode 0 0"
	done
	for o in $OVERLAYS; do
		(cd "$o" && find . -type f | sort | sed 's|^\.||') |
			while read -r f; do
				mode=0644; [ -x "$o$f" ] && mode=0755
				echo "file $f $o$f $mode 0 0"
			done
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
