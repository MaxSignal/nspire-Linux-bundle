Linux @KERNEL@ for the TI-Nspire CX / CX CAS, Touchpad and Clickpad
(the CX II is not supported).

> [!WARNING]
> Experimental. Linux keeps its files in an image file of the calculator's
> filesystem and writes into it directly. This has only been tested on an
> emulator so far: back up your documents first. If the filesystem does not
> look as expected, Linux does not write to it (`dmesg | grep tifs` says why).

## Downloads

| File | System |
|---|---|
| `@LINUX_ZIP@` | Minimal Linux (BusyBox), with fastfetch |
| `@LINUX_ZIP_NOFF@` | The same without fastfetch |
| `@OPENWRT_ZIP@` | OpenWrt @OPENWRT@, set up as a client (no router software), with fastfetch |
| `@OPENWRT_ZIP_NOFF@` | The same without fastfetch |

The minimal Linux and OpenWrt can be installed side by side: their file
names do not overlap. A ZIP and its version without fastfetch have the same
file names. fastfetch takes about 1.5 MB.

## Installation

1. Install [Ndless](https://ndless.me/) on the calculator.
2. Unzip, and send the files of the `linux` folder to a folder named
   `linux` on the calculator (`/documents/linux/`), with TI-Nspire Computer
   Link or the TI-Nspire Student Software.
3. Add this line to `/documents/ndless/ndless.cfg.tns` (copy it to the
   computer, edit it with a text editor and send it back):

   ```
   ext.ll2=linuxloader2
   ```

4. Optional: before sending it, edit `linux.cfg.tns` (`openwrt.cfg.tns`) to
   choose how much space Linux gets (see below).

## Starting Linux

Open the file for your model in the `linux` folder:

| Model | Minimal Linux | OpenWrt |
|---|---|---|
| CX / CX CAS | `linux-cx` | `openwrt-cx` |
| Touchpad | `linux-tp` | `openwrt-tp` |
| Clickpad | `linux-clp` | `openwrt-clp` |

The first time, the loader creates the image file in which Linux keeps its
files (`rootfs.img` / `openwrt.img` in the `linux` folder) and shows its
progress; Linux then formats it and installs itself into it, which takes a
while. Later starts use it as it is. To leave Linux, run `reboot`: the
calculator restarts into the TI-Nspire OS (as after any reset, Ndless may
have to be installed again).

The shell runs on the screen and keypad, and on the serial port (115200
bauds). `fastfetch --logo none` fits the screen better than `fastfetch`.

## Space for Linux

`linux.cfg.tns` (`openwrt.cfg.tns`):

```
size = max     # all the free space, minus "reserve"; or a size such as 64M
reserve = 2M   # space left to the TI-Nspire OS with "max"
```

When there is not enough free space for the size asked for, `max` is used.
The image is never smaller than what the system needs (`min`, set in the
file: 3 MB for the minimal Linux, 7 MB for OpenWrt, 1 MB less without
fastfetch); without the free space for it, Linux runs from RAM. On a
Touchpad or a Clickpad (32 MB of flash, most of it the TI-Nspire OS's),
OpenWrt runs with an 8 MB image.

OpenWrt's root filesystem comes as `openwrt.tar.gz` (2.5 MB), which the
loader writes into the new image: OpenWrt needs that much more free space
the first time. Once OpenWrt has started, you may delete `openwrt.tar.gz`
to get the space back; it is only needed again to make a new image.
To change the size later, or to start over with a clean system, delete
`rootfs.img` (`openwrt.img`) in the TI-Nspire file browser and start Linux
again. Without the image file (or when it cannot be written to), Linux runs
from RAM and forgets everything when turned off.

## Network

Connect the calculator to a computer with a USB cable: it appears as a USB
Ethernet adapter (CDC NCM: Windows 10 or later, Linux, macOS). Share the computer's
internet connection with it (Windows: Internet Connection Sharing; Linux:
"Shared to other computers" in NetworkManager; macOS: Internet Sharing), and
the calculator gets an address by DHCP on `usb0`.

- Minimal Linux: `ip`, `ping`, `nslookup` and `wget` (HTTPS, without
  certificate checks).
- OpenWrt: the official packages, without the router ones (DHCP/DNS server,
  firewall, PPP, web interface). Install more with `apk add`; kernel modules
  (`kmod-*`) cannot be used, as the kernel is not OpenWrt's.

## Build

@BUILD_INFO@

SHA-256:

```
@SHA256@
```
