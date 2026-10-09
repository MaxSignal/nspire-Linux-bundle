#!/bin/sh
# Boot the kernel, device trees and initrds on the Firebird emulator, the way
# linuxloader2 hands them over (initrd and command line in /chosen):
#  - busybox: every model boots from RAM and reaches a shell; then, with a
#    synthetic TI-Nspire filesystem holding a new image file (as the loader
#    creates it), the first boot formats and fills the image, and a second
#    boot runs from it and finds what the first one wrote; then the flash is
#    read independently of the driver (tests/tifs/readfs.py, tifscheck.py):
#    the TI-Nspire OS's files and the FlashFX pages to leave alone are
#    unchanged. The Touchpad's filesystem is laid out as on a real one (no
#    free unit, sequence numbers per region, discard records, regions with
#    data in all their pages); the others as Goplat describes FlashFX;
#  - openwrt: the same two boots on the CX and on the Touchpad (8 MB image),
#    up to a login shell; and with an image too small for it, which is left
#    new while OpenWrt runs from RAM.
# Usage: boot-test.sh [busybox] [openwrt]   (default: the initrds that were built)
# BOOT_TEST_MODELS limits the models of the busybox test (default: cx tp clp).
set -eu
cd "$(dirname "$0")/.."
TOP=$(pwd)
. scripts/versions.sh

FB=${FIREBIRD:-}
if [ -z "$FB" ]; then
	SRC=$WORK/firebird
	if [ ! -d "$SRC" ]; then
		git clone --branch "$FIREBIRD_REF" "$FIREBIRD_REPO" "$SRC"
		git -C "$SRC" submodule update --init core/gif-h
	fi
	make -C "$SRC/headless" -j"$JOBS" >/dev/null
	FB=$SRC/headless/firebird-headless
fi
[ -f "$TOP/tests/tifs/libhamming.so" ] ||
	sh "$TOP/tests/tifs/build-hamming.sh" "$OUT/ecc-sw-hamming.c"

if [ $# -eq 0 ]; then
	[ -f "$OUT/rootfs.cpio.gz" ] && set -- "$@" busybox
	[ -f "$OUT/openwrt.cpio.gz" ] && set -- "$@" openwrt
fi

REL=$(cat "$OUT/kernel.release")
INITRD_ADDR=0x11800000
T=$WORK/boot-test
rm -rf "$T"
mkdir -p "$T"
status=0

pass() { echo "PASS $1"; }
fail() {
	echo "FAIL $1 (log: $2)"
	tail -40 "$2" | sed 's/^/    /'
	status=1
}

# boot NAME MODEL INITRD FLASH TIMEOUT EXTRA_BOOTARGS < SCRIPT
# Boots as the loader would, with the command line of the .ll2 scripts;
# the flash image is kept (and saved back) between boots.
boot() {
	name=$1 m=$2 initrd=$3 flash=$4 tmo=$5 extra=$6
	case $m in cx) tty=ttyAMA0;; *) tty=ttyS0;; esac
	end=$(printf '0x%x' $((INITRD_ADDR + $(wc -c < "$initrd"))))
	{
		"$OUT/dtc" -q -I dtb -O dts "$OUT/nspire-$m.dtb"
		cat <<DTS
/ {
	chosen {
		bootargs = "console=$tty,115200n8 console=tty0 fbcon=font:6x8$extra";
		linux,initrd-start = <$INITRD_ADDR>;
		linux,initrd-end = <$end>;
	};
};
DTS
	} | "$OUT/dtc" -q -I dts -O dtb -o "$T/$name.dtb" -
	cat > "$T/$name.script"
	timeout $((tmo * 4 + 120)) "$FB" --model "$m" --flash "$flash" --kernel "$OUT/zImage" \
		--dtb "$T/$name.dtb" --load "$INITRD_ADDR=$initrd" --save-flash --timeout "$tmo" \
		< "$T/$name.script" 2>&1 | tr -d '\r' > "$T/$name.log" || true
	LOG=$T/$name.log
}

# new_flash MODEL FLASH IMAGE_NAME IMAGE_KIB [PAYLOAD]: a TI-Nspire filesystem
# holding a new image file (with the payload the loader writes into it): on
# the Touchpad, laid out as on a real one; else with old copies of pages in
# all but 4 units
new_flash() {
	rm -f "$2"
	"$FB" --model "$1" --flash "$2" --kernel /dev/null --dtb /dev/null --timeout 0 \
		</dev/null >/dev/null 2>&1 || true
	case $1 in tp) layout="--layout real";; *) layout="--free-units 4";; esac
	python3 -I "$TOP/tests/tifs/mkfsimage.py" "$1" "$2" --image-name "$3" --image-kib "$4" \
		${5:+--payload "$5"} $layout >/dev/null
}

# check_flash MODEL FLASH IMAGE_NAME: read the flash independently of the
# driver; only the image may have changed
check_flash() {
	case $1 in
	tp) python3 -I "$TOP/tests/tifs/tifscheck.py" "$2" --compare "$2.manifest.json" \
		--allow "/documents/linux/$3" ;;
	*) python3 -I "$TOP/tests/tifs/readfs.py" $1 "$2" --image "/documents/linux/$3" ;;
	esac
}

clean() { ! grep -a -q -E "Kernel panic|BUG:|Oops|I/O error|EXT2-fs .*error|nspire-tifs: read-only" "$1"; }

for variant; do
	case $variant in
	busybox)
		initrd=$OUT/rootfs.cpio.gz image=rootfs.img.tns
		for m in ${BOOT_TEST_MODELS:-cx tp clp}; do
			# From RAM, without an image
			rm -f "$T/$m.flash"
			# LCD control register: 4 bpp palette on a monochrome 8 bit
			# STN panel (classic), RGB565 TFT (CX)
			case $m in cx) lcd="0xC0000018 0x0000192D";; *) lcd="0xC000001C 0x00000855";; esac
			boot "$m-ram" $m "$initrd" "$T/$m.flash" 120 "" <<SCRIPT
!wait nspire:~#
echo "lcd \$(devmem ${lcd% *})"; uname -r; tr -d '\0' < /proc/device-tree/model; echo; cat /proc/mtd | wc -l; ls /sys/class/rtc /sys/class/leds /sys/bus/iio/devices; ip -o link | cut -d' ' -f2; ps | grep -q "[u]dhcpc -i usb0" && echo dhcp-client-running; fastfetch --pipe --logo none -s os:kernel:host:cpu:memory; echo CHECK-\$((40+2))
!wait CHECK-42
!delay 300
!screenshot $T/$m-ram.ppm
!quit 0
SCRIPT
			if grep -a -q "^$REL" "$LOG" && grep -a -q "Unpacking initramfs" "$LOG" &&
			   grep -a -q "^lcd ${lcd#* }$" "$LOG" &&
			   grep -a -q "rtc0" "$LOG" && grep -a -q "green:status" "$LOG" &&
			   grep -a -q "^6$" "$LOG" && grep -a -q "^usb0:$" "$LOG" &&
			   grep -a -q "^dhcp-client-running" "$LOG" &&
			   grep -a -q "^Kernel: Linux $REL" "$LOG" && clean "$LOG"; then
				pass "busybox $m from RAM"
			else
				fail "busybox $m from RAM" "$LOG"
			fi

			# First boot with an image: formatted and filled
			new_flash $m "$T/$m.flash" $image 8192
			boot "$m-first" $m "$initrd" "$T/$m.flash" 400 " nspire_tifs.path=/documents/linux/$image" <<'SCRIPT'
!wait nspire:~#
grep " / " /proc/mounts; echo kept-$((6*7)) > /root/note; sync; echo CHECK-$((40+2))
!wait CHECK-42
!delay 300
!quit 0
SCRIPT
			if grep -a -q "init: first boot: formatting" "$LOG" &&
			   grep -a -q "^/dev/tifs0 / ext2 rw" "$LOG" && clean "$LOG"; then
				pass "busybox $m first boot with an image"
			else
				fail "busybox $m first boot with an image" "$LOG"
			fi

			# Second boot: runs from the image
			boot "$m-second" $m "$initrd" "$T/$m.flash" 300 " nspire_tifs.path=/documents/linux/$image" <<'SCRIPT'
!wait nspire:~#
grep " / " /proc/mounts; cat /root/note; echo CHECK-$((40+2))
!wait CHECK-42
!delay 300
!quit 0
SCRIPT
			if ! grep -a -q "init: first boot" "$LOG" && grep -a -q "^kept-42" "$LOG" &&
			   grep -a -q "^/dev/tifs0 / ext2 rw" "$LOG" && clean "$LOG"; then
				pass "busybox $m second boot from the image"
			else
				fail "busybox $m second boot from the image" "$LOG"
			fi

			# After Linux wrote to the flash, read independently of the
			# driver: the TI-Nspire OS's files and the pages to leave
			# alone are unchanged
			if check_flash $m "$T/$m.flash" $image > "$T/$m-readfs.log" 2>&1; then
				pass "busybox $m TI files and pages to leave alone unchanged"
			else
				fail "busybox $m TI files and pages to leave alone unchanged" "$T/$m-readfs.log"
			fi
		done
		;;
	openwrt)
		initrd=$OUT/openwrt.cpio.gz image=openwrt.img.tns
		# The Touchpad with an image as small as it may get (32 MB of
		# NAND, most of it the TI-Nspire OS's) and its 32 MB of RAM
		for m in ${OPENWRT_MODELS:-cx tp}; do
		case $m in cx) kib=32768;; *) kib=8192;; esac
		new_flash $m "$T/openwrt-$m.flash" $image $kib "$OUT/openwrt.tar.gz"
		for b in first second; do
			boot "openwrt-$m-$b" $m "$initrd" "$T/openwrt-$m.flash" ${OPENWRT_TIMEOUT:-900} " nspire_tifs.path=/documents/linux/$image" <<SCRIPT
!wait Please press Enter to activate this console.
!delay 500

!wait root@
n=0; until ubus call system board >/dev/null 2>&1 || [ \$n -ge 300 ]; do sleep 1; n=\$((n+1)); done; grep " / " /proc/mounts; ubus call system board | grep -E 'release|"kernel"|description'; echo "hostname \$(uci get system.@system[0].hostname)"; echo "wan \$(uci get network.wan.device) \$(uci get network.wan.proto)"; fastfetch --pipe --logo none -s os:kernel:memory:disk; [ -e /root/note ] && cat /root/note; echo kept-\$((6*7)) > /root/note; sync; echo CHECK-\$((40+2))
!wait CHECK-42
!delay 300
!quit 0
SCRIPT
			ok=1
			grep -a -q "^/dev/\(tifs0\|root\) / ext2 rw" "$LOG" && grep -a -q "\"kernel\": \"$REL\"" "$LOG" &&
				grep -a -q "OpenWrt $OPENWRT_VERSION" "$LOG" && grep -a -q "^hostname nspire$" "$LOG" && grep -a -q "^wan usb0 dhcp$" "$LOG" &&
				grep -a -q "^OS: OpenWrt $OPENWRT_VERSION" "$LOG" &&
				clean "$LOG" || ok=0
			if [ $b = first ]; then
				grep -a -q "init: reading openwrt.tar.gz from the image" "$LOG" &&
					grep -a -q "init: unpacking openwrt" "$LOG" || ok=0
			else
				grep -a -q "^kept-42" "$LOG" && ! grep -a -q "init: first boot" "$LOG" || ok=0
			fi
			if [ $ok = 1 ]; then pass "openwrt $m $b boot"; else fail "openwrt $m $b boot" "$LOG"; fi
		done
		if check_flash $m "$T/openwrt-$m.flash" $image > "$T/openwrt-$m-check.log" 2>&1; then
			pass "openwrt $m TI files unchanged"
		else
			fail "openwrt $m TI files unchanged" "$T/openwrt-$m-check.log"
		fi
		done

		# A new image too small for OpenWrt: left new, OpenWrt runs from RAM
		new_flash tp "$T/openwrt-small.flash" $image 4096 "$OUT/openwrt.tar.gz"
		boot "openwrt-tp-small" tp "$initrd" "$T/openwrt-small.flash" ${OPENWRT_TIMEOUT:-900} " nspire_tifs.path=/documents/linux/$image" <<SCRIPT
!wait Please press Enter to activate this console.
!delay 500

!wait root@
grep " / " /proc/mounts; fastfetch --pipe --logo none -s os; echo CHECK-\$((40+2))
!wait CHECK-42
!delay 300
!quit 0
SCRIPT
		if grep -a -q "init: the image is too small for this system" "$LOG" &&
		   ! grep -a -q "init: first boot: formatting" "$LOG" &&
		   grep -a -q "^tmpfs / tmpfs" "$LOG" && grep -a -q "^OS: OpenWrt" "$LOG" && clean "$LOG"; then
			pass "openwrt tp with a too small image, from RAM"
		else
			fail "openwrt tp with a too small image, from RAM" "$LOG"
		fi
		;;
	*) echo "unknown variant $variant" >&2; exit 1;;
	esac
done
exit $status
