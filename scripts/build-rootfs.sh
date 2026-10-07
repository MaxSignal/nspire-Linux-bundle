#!/bin/sh
# Build a static BusyBox and pack the root filesystem as a gzipped cpio
# archive (an initramfs passed as initrd by the loader).
# Output: $OUT/rootfs.cpio.gz
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

# Toolchain: ARMv5 musl from Bootlin, unless CROSS_COMPILE points elsewhere
if [ -z "${ROOTFS_CROSS_COMPILE:-}" ]; then
	if [ ! -d "$WORK/musl-toolchain" ]; then
		mkdir -p "$WORK/musl-toolchain"
		curl -fsSL "$MUSL_TOOLCHAIN_URL" | tar -xJ -C "$WORK/musl-toolchain" --strip-components=1
	fi
	ROOTFS_CROSS_COMPILE=$WORK/musl-toolchain/bin/arm-buildroot-linux-musleabi-
fi

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

LIST=$WORK/rootfs.list
{
	cat "$TOP/rootfs/devices.list"
	echo "file /bin/busybox $BB/busybox 0755 0 0"
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

"$GEN" "$LIST" | gzip -9 -n > "$OUT/rootfs.cpio.gz"
echo "rootfs: $(wc -c < "$OUT/rootfs.cpio.gz") bytes, busybox $BUSYBOX_VERSION"
