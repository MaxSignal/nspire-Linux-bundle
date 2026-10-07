#!/bin/sh
# Build zImage and the TI-Nspire device trees.
# Output: $OUT/zImage, $OUT/nspire-{cx,tp,clp}.dtb, $OUT/kernel.release
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

SRC=${KERNEL_SRC:-$WORK/linux}
if [ -z "${KERNEL_SRC:-}" ]; then
	rm -rf "$SRC"
	git clone --depth 1 --branch "$KERNEL_REF" "$KERNEL_REPO" "$SRC"
fi

B=$WORK/linux-build
rm -rf "$B"
make -C "$SRC" O="$B" ARCH=arm CROSS_COMPILE="$KERNEL_CROSS_COMPILE" \
	multi_v4t_defconfig nspire.config
"$SRC"/scripts/kconfig/merge_config.sh -m -O "$B" "$B/.config" "$TOP/config/kernel.config"
make -C "$SRC" O="$B" ARCH=arm CROSS_COMPILE="$KERNEL_CROSS_COMPILE" olddefconfig

# Fail if a requested option did not make it into the configuration
for f in "$SRC/arch/arm/configs/nspire.config" "$TOP/config/kernel.config"; do
	grep '^CONFIG_' "$f" | while IFS= read -r line; do
		grep -qxF "$line" "$B/.config" || { echo "missing in .config: $line" >&2; exit 1; }
	done
done

make -C "$SRC" O="$B" ARCH=arm CROSS_COMPILE="$KERNEL_CROSS_COMPILE" -j"$JOBS" zImage dtbs

cp "$B/arch/arm/boot/zImage" "$OUT/zImage"
for m in cx tp clp; do
	cp "$B/arch/arm/boot/dts/nspire/nspire-$m.dtb" "$OUT/"
done
make -s -C "$SRC" O="$B" ARCH=arm kernelrelease > "$OUT/kernel.release"
# dtc, gen_init_cpio and the NAND ECC code, for the rootfs and the boot test
cp "$B/scripts/dtc/dtc" "$OUT/dtc"
cp "$SRC/drivers/mtd/nand/ecc-sw-hamming.c" "$OUT/"
cc -O2 -o "$OUT/gen_init_cpio" "$SRC/usr/gen_init_cpio.c"
echo "kernel $(cat "$OUT/kernel.release") built"
