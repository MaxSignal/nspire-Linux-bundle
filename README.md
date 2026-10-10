# nspire-linux-bundle

Builds everything needed to run Linux on a TI-Nspire (CX / CX CAS, Touchpad,
Clickpad): the loader, the kernel, the device trees and a root filesystem,
and zips the files to copy to the calculator. The CX II is not supported.

CXs from hardware revision W on have a 240x320 panel. The kernel tells it
from how the TI-Nspire OS left the LCD controller and shows the picture
turned, with the same files as the other CXs. This has only been tried on
Firebird's emulation of that panel. Ndless supports these calculators from
OS 4.2 on, and the TI-Nspire filesystem has only been checked against
OS 3.6 on real calculators: should the driver find something it does not
know there, it stays read-only and Linux runs from RAM.

| ZIP | Root filesystem |
|---|---|
| `nspire-linux-<kernel>.zip` | Minimal BusyBox system and fastfetch (initrd of about 900 KB) |
| `nspire-openwrt-<version>-<kernel>.zip` | OpenWrt for the ARM926EJ-S (official at91/sam9x packages, put together by the official ImageBuilder), set up as a client |

Each also comes without fastfetch (`…-no-fastfetch.zip`, 1.5 MB less).

The `linux/` folder of a ZIP goes to `/documents/linux/` on the calculator.
The two variants use different file names, so both can be installed side by
side.

Both variants reach the network through Ethernet over USB (`usb0`, CDC NCM)
as a DHCP client: share the computer's connection with the
calculator to get online. The minimal variant has `ip`, `udhcpc`, `ping`,
`nslookup` and `wget` (HTTPS without certificate checks).

[fastfetch](https://github.com/fastfetch-cli/fastfetch) is built here as a
static binary (OpenWrt does not package it).

The OpenWrt variant leaves out the router software (DHCP/DNS server,
firewall, PPP, web interface). The packages to leave out are listed in
`OPENWRT_PACKAGES` (`scripts/versions.sh`), and the files changed for the
TI-Nspire are in `openwrt/`.

## Components

| | Repository | Branch |
|---|---|---|
| Kernel | [MaxSignal/linux](https://github.com/MaxSignal/linux) | `nspire-7.2.y` (Linux 7.2.y stable + TI-Nspire drivers) |
| Loader | [MaxSignal/nspire-linux-loader2](https://github.com/MaxSignal/nspire-linux-loader2) | `master` |
| Ndless SDK | release `latest` of [MaxSignal/build-toolchain](https://github.com/MaxSignal/build-toolchain) | |
| Emulator (tests) | [MaxSignal/firebird](https://github.com/MaxSignal/firebird) | `linux-direct-boot` |

Versions and download locations are in `scripts/versions.sh`; each can be
overridden from the environment.

## How it boots

1. Opening `linux-<model>.ll2.tns` (`openwrt-<model>.ll2.tns` for OpenWrt)
   runs the script with linuxloader2 through Ndless.
2. The `rootimg` command reads the configuration file (`linux.cfg.tns` /
   `openwrt.cfg.tns`) and, the first time, creates an image file in the
   TI-Nspire filesystem (`rootfs.img.tns` / `openwrt.img.tns`), showing a
   progress bar:
   - `size = max`: all the free space minus `reserve` (2 MB in the configuration files);
   - `size = 64M` and so on: that size, or the same as `max` when there is
     not enough free space;
   - never less than `min`, the space the system needs (computed by the
     build from its files); without the free space for it, there is no
     image.
3. The kernel's `nspire-tifs` driver reads FlashFX and Reliance, finds the
   file and exposes its contents as `/dev/tifs0`. Writes replace only the
   pages of the file's contents, the way FlashFX does it, and never touch
   the TI-Nspire OS's metadata.
4. The initrd's `/init` formats the image (ext2) if needed and fills it with
   the root filesystem, then switches to it. OpenWrt's root filesystem is
   too large to go through the loader's RAM (about 4 MB on a Touchpad, the
   kernel included) in the initrd: it comes as a file of its own
   (`openwrt.tar.gz.tns`), which the loader writes into the new image
   (`payload` setting), and which `/init` takes out of it before formatting
   it. Later boots use it as it is. Without an image, when the image is
   read-only, or when a new image is too small for the system (it is then
   left new, for the loader to grow), the system runs from RAM.

To recreate the image (for instance with another size), delete the image
file in the TI-Nspire file browser and boot again.

## Building

The GitHub Actions workflow (`.github/workflows/build.yml`) builds
everything on every push, boots the result on the emulator and keeps the
ZIPs as artifacts. Each build of `main` (tag `build-<run number>`), and
each pushed `v*` tag, makes a new release marked as the latest one; older
releases are kept. Release notes
(installation and use, versions, checksums) are made from
`release/notes.md` by `scripts/release-notes.sh`.

Locally:

```sh
# Debian/Ubuntu: gcc-arm-linux-gnueabi bc bison flex libssl-dev zip
scripts/build-kernel.sh     # out/zImage, out/nspire-*.dtb
scripts/build-fastfetch.sh  # out/fastfetch (static musl; needs cmake, ninja)
scripts/build-rootfs.sh     # out/rootfs.cpio.gz (BusyBox, static musl)
scripts/build-openwrt.sh    # out/openwrt.cpio.gz (OpenWrt ImageBuilder: needs gawk, zstd...)
scripts/build-loader.sh     # out/linuxloader2.tns (needs an Ubuntu 22.04 like system)
scripts/boot-test.sh        # boot test on Firebird
scripts/package.sh          # out/*.zip
scripts/release-notes.sh    # out/release-notes.md
```

`KERNEL_SRC` / `LOADER_SRC` select local source trees instead of cloning.

### Debug build

`DEBUG=1` (for every script; best with its own `OUT`, for instance
`OUT=$PWD/out-debug`) makes an investigation build, never a release: its
ZIPs are named `*-debug`.

- The kernel shows what the TI-Nspire filesystem image driver finds where
  it does not understand the flash (`config/kernel-debug.config`).
- The minimal system gets BusyBox `nc` and `udhcpd`, the NAND tools of
  `rootfs/debug/tools`, and starts `nspire-pc-link` at boot
  (`rootfs/debug`): the calculator takes 192.168.7.1 on `usb0`, hands the
  computer on the USB cable an address by DHCP (no gateway, so its other
  connections stay as they are) and gives each connection to port 2323 a
  shell reading its commands from the connection. From the computer:

```sh
echo 'dmesg | grep tifs' | nc -N 192.168.7.1 2323
echo nspire-flashdump | nc -N 192.168.7.1 2323 > flash.bin
echo 'cat /sys/bus/nvmem/devices/nspire-bootrom/nvmem' | nc -N 192.168.7.1 2323 > boot1.bin
```

`nspire-flashdump` writes the whole NAND chip raw (each page's data and
spare area) in the layout of the Firebird emulator's flash images. With the
calculator's boot ROM, Firebird then runs its own boot2 and TI-Nspire OS on
that flash, which shows whether they still accept what Linux wrote.

## Tests

`scripts/boot-test.sh` boots on Firebird (a version that can start Linux
directly) the way the loader hands the kernel over (initrd and command line
in `/chosen`):

- BusyBox variant: each of the three models boots from RAM (and the CX
  with the HW-W panel, where a row drawn into `/dev/fb0` has to show as a
  row); then, on a
  TI-Nspire filesystem (FlashFX Pro + Reliance) made by
  `tests/tifs/mkfsimage.py` holding a new, tagged image file as the loader
  creates it, the first boot formats and fills the image, and a second boot
  runs from it and finds the file the first one wrote.
- OpenWrt variant: the same first and second boots on the CX, and on the
  Touchpad with an 8 MB image (OpenWrt takes about 5.7 MB of it, and 11 of
  the 23 MB of RAM Linux gets there).

The synthetic filesystem follows Hackspire and Goplat's analysis and may
differ from what is on real calculators. This is why the driver checks the
spare area layout, the ECC and the file's tags before writing anything, and
stays read-only when they do not match.

## References

Everything consulted while porting, fixing and testing, by topic.

### TI-Nspire hardware and software

- [Hackspire](https://hackspire.org/) ([sources](https://github.com/beyond-ndless/hackspire.org)):
  [Memory-mapped I/O ports](https://hackspire.org/index.php/Memory-mapped_I/O_ports),
  Hardware, Clock speed, Interrupts, Timers, Keypads, GPIO pins,
  NAND memory layout, Internal filesystem (the FlashFX unit header layout),
  OS upgrade files, USB protocol, Zehn, Libndls and
  [Linux](https://hackspire.org/index.php/Linux).
- Goplat's analysis of FlashFX Pro and Reliance on the TI-Nspire, in the
  Omnimaga thread "Bypassing TI-Nspire RSA signatures now possible?"
  ([page 60](https://www.omnimaga.org/news/bypassing-ti-nspire-rsa-signatures-now-possible/60/),
  [75](https://www.omnimaga.org/news/bypassing-ti-nspire-rsa-signatures-now-possible/75/),
  [90](https://www.omnimaga.org/news/bypassing-ti-nspire-rsa-signatures-now-possible/90/)).
- [Firebird](https://github.com/nspire-emus/firebird) sources: the
  emulated peripherals (NAND controllers, LCD controller, HW-W LCD, PMU,
  USB), and its flash image format.
- [Ndless](https://github.com/ndless-nspire/Ndless) sources and SDK: the
  Zehn format and flags, `lcd_type()`/`lcd_blit()`, and the LCD
  compatibility mode for HW-W (`lcd_compat.c`).
- [TI-Nspire OS downloads](https://education.ti.com/en/software/details/en/33AADF01417343C6B4DCA1A8199647F4/ti-nspire_os)
  (Texas Instruments) and the [TI-Planet archives](https://tiplanet.org/),
  searched for OS files; the OS files used to restore the test calculators
  were made from their own flash dumps.

### Linux on the TI-Nspire

- Daniel Tang's TI-Nspire Linux port: [tangrs/linux](https://github.com/tangrs/linux)
  (`nspire`, `nand` and `nspire-dt` branches), the base of the drivers
  ported here, and the original [nspire-linux-loader2](https://github.com/tangrs/nspire-linux-loader2).
- [Vogtinator/linux](https://github.com/Vogtinator/linux), including the
  [`cxII-clean`](https://github.com/Vogtinator/linux/commits/cxII-clean)
  branch (CX II support and a panel for HW-W), and
  [Vogtinator/nspire-linux-configs](https://github.com/Vogtinator/nspire-linux-configs).
- [nspire-linux-loader2 issue #7, "Support for HW-W"](https://github.com/tangrs/nspire-linux-loader2/issues/7).
- Cemetech threads: [running Linux on the CX II](https://www.cemetech.net/forum/viewtopic.php?p=295953)
  and the [full guide to Linux on the TI-Nspire](https://www.cemetech.net/forum/viewtopic.php?p=299183).
- The mainline kernel ([torvalds/linux](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git),
  [stable](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git)):
  the existing TI-Nspire support, the PL353 NAND controller driver
  (`pl35x-nand-controller.c`), the PL111 DRM driver, `panel-simple` and
  the device tree bindings.

### Tools and components

- [n-link](https://lights0123.com/n-link/) and the
  [libnspire](https://crates.io/crates/libnspire) crate (file transfers
  to the calculator's OS over USB).
- [OpenWrt](https://openwrt.org/): the at91/sam9x release
  [downloads](https://downloads.openwrt.org/releases/), ImageBuilder and
  [procd](https://git.openwrt.org/project/procd.git).
- [BusyBox](https://busybox.net/), [fastfetch](https://github.com/fastfetch-cli/fastfetch)
  and the [Bootlin toolchains](https://toolchains.bootlin.com/) (armv5-eabi, musl).
- [stepney141/ndless-docker](https://github.com/stepney141/ndless-docker)
  and Ndless's own CI workflow, for building the Ndless SDK in CI.
