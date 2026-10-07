# nspire-linux-bundle

Builds everything needed to run Linux on a TI-Nspire (CX / CX CAS, Touchpad,
Clickpad): the loader, the kernel, the device trees and a root filesystem,
and zips the files to copy to the calculator. The CX II is not supported.

| ZIP | Root filesystem |
|---|---|
| `nspire-linux-<kernel>.zip` | Minimal BusyBox system (initrd of about 300 KB) |
| `nspire-openwrt-<version>-<kernel>.zip` | OpenWrt for the ARM926EJ-S (official at91/sam9x packages, put together by the official ImageBuilder), set up as a client |

The `linux/` folder of a ZIP goes to `/documents/linux/` on the calculator.
The two variants use different file names, so both can be installed side by
side.

Both variants reach the network through Ethernet over USB (`usb0`, CDC ECM
or RNDIS) as a DHCP client: share the computer's connection with the
calculator to get online. The minimal variant has `ip`, `udhcpc`, `ping`,
`nslookup` and `wget` (HTTPS without certificate checks).

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
   - `size = max`: all the free space minus `reserve` (2 MB by default);
   - `size = 64M` and so on: that size, or the same as `max` when there is
     not enough free space.
3. The kernel's `nspire-tifs` driver reads FlashFX and Reliance, finds the
   file and exposes its contents as `/dev/tifs0`. Writes replace only the
   pages of the file's contents, the way FlashFX does it, and never touch
   the TI-Nspire OS's metadata.
4. The initrd's `/init` formats the image (ext2) if needed and fills it with
   the root filesystem (with OpenWrt in the OpenWrt variant), then switches
   to it. Later boots use it as it is. Without an image, or when the image
   is read-only, the system runs from RAM.

To recreate the image (for instance with another size), delete the image
file in the TI-Nspire file browser and boot again.

## Building

The GitHub Actions workflow (`.github/workflows/build.yml`) builds
everything on every push, boots the result on the emulator and keeps the
ZIPs as artifacts. Builds of `main` replace the `latest` release, and
pushing a `v*` tag creates a release of its own. Release notes
(installation and use, versions, checksums) are made from
`release/notes.md` by `scripts/release-notes.sh`.

Locally:

```sh
# Debian/Ubuntu: gcc-arm-linux-gnueabi bc bison flex libssl-dev zip
scripts/build-kernel.sh     # out/zImage, out/nspire-*.dtb
scripts/build-rootfs.sh     # out/rootfs.cpio.gz (BusyBox, static musl)
scripts/build-openwrt.sh    # out/openwrt.cpio.gz (OpenWrt ImageBuilder: needs gawk, zstd...)
scripts/build-loader.sh     # out/linuxloader2.tns (needs an Ubuntu 22.04 like system)
scripts/boot-test.sh        # boot test on Firebird
scripts/package.sh          # out/*.zip
scripts/release-notes.sh    # out/release-notes.md
```

`KERNEL_SRC` / `LOADER_SRC` select local source trees instead of cloning.

## Tests

`scripts/boot-test.sh` boots on Firebird (a version that can start Linux
directly) the way the loader hands the kernel over (initrd and command line
in `/chosen`):

- BusyBox variant: each of the three models boots from RAM; then, on a
  TI-Nspire filesystem (FlashFX Pro + Reliance) made by
  `tests/tifs/mkfsimage.py` holding a new, tagged image file as the loader
  creates it, the first boot formats and fills the image, and a second boot
  runs from it and finds the file the first one wrote.
- OpenWrt variant: the same first and second boots on the CX.

The synthetic filesystem follows Hackspire and Goplat's analysis and may
differ from what is on real calculators. This is why the driver checks the
spare area layout, the ECC and the file's tags before writing anything, and
stays read-only when they do not match.
