# Sources and versions used by the build scripts. Every value can be
# overridden from the environment.

# Kernel with the TI-Nspire drivers (Linux stable + nspire patches)
: "${KERNEL_REPO:=https://github.com/MaxSignal/linux.git}"
: "${KERNEL_REF:=nspire-7.2.y}"

# Linux loader (runs under Ndless on the calculator)
: "${LOADER_REPO:=https://github.com/MaxSignal/nspire-linux-loader2.git}"
: "${LOADER_REF:=master}"

# Prebuilt Ndless SDK (toolchain + libraries), built by MaxSignal/build-toolchain
: "${NDLESS_SDK_URL:=https://github.com/MaxSignal/build-toolchain/releases/download/latest/ndless-sdk.tar.gz}"

# Emulator used for the boot test (Firebird with direct Linux boot)
: "${FIREBIRD_REPO:=https://github.com/MaxSignal/firebird.git}"
: "${FIREBIRD_REF:=linux-direct-boot}"

# Userspace
: "${BUSYBOX_VERSION:=1.37.0}"
: "${BUSYBOX_URL:=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2}"
: "${MUSL_TOOLCHAIN_URL:=https://toolchains.bootlin.com/downloads/releases/toolchains/armv5-eabi/tarballs/armv5-eabi--musl--stable-2025.08-1.tar.xz}"

# fastfetch, in both root filesystems (static, musl)
: "${FASTFETCH_VERSION:=2.69.0}"
: "${FASTFETCH_SHA256:=d0e42faf307e39e7b531d632745a56e4eb558a6545f557280099c622562355ee}"
: "${FASTFETCH_URL:=https://github.com/fastfetch-cli/fastfetch/archive/refs/tags/${FASTFETCH_VERSION}.tar.gz}"

# OpenWrt variant: official packages for the ARM926EJ-S (at91/sam9x target),
# put together by the official ImageBuilder
: "${OPENWRT_VERSION:=25.12.5}"
: "${OPENWRT_URL:=https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/at91/sam9x}"
# Used as a client, not as a router: no DHCP/DNS server, firewall, PPP,
# web interface, nor the kernel modules of the at91 boards
: "${OPENWRT_PACKAGES:=-dnsmasq -firewall4 -nftables -kmod-nft-offload -odhcpd-ipv6only -ppp -ppp-mod-pppoe -mtd -kmod-usb-ohci -kmod-at91-udc -kmod-usb-gadget-eth -procd-ujail}"

# Kernel cross compiler (Debian/Ubuntu: gcc-arm-linux-gnueabi)
: "${KERNEL_CROSS_COMPILE:=arm-linux-gnueabi-}"

: "${OUT:=$(pwd)/out}"
: "${WORK:=$(pwd)/work}"
JOBS=${JOBS:-$(nproc)}
mkdir -p "$OUT" "$WORK"
