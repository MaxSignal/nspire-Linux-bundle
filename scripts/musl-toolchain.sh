# Sourced: ARMv5 musl toolchain from Bootlin, unless ROOTFS_CROSS_COMPILE
# points elsewhere. Sets ROOTFS_CROSS_COMPILE.
if [ -z "${ROOTFS_CROSS_COMPILE:-}" ]; then
	if [ ! -d "$WORK/musl-toolchain" ]; then
		mkdir -p "$WORK/musl-toolchain"
		curl -fsSL "$MUSL_TOOLCHAIN_URL" | tar -xJ -C "$WORK/musl-toolchain" --strip-components=1
	fi
	ROOTFS_CROSS_COMPILE=$WORK/musl-toolchain/bin/arm-buildroot-linux-musleabi-
fi
