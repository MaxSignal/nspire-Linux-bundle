#!/usr/bin/env python3
"""Space (KiB) a root filesystem needs in an ext2 image: its files in 1 KiB
blocks (with indirect blocks), its directories and inodes, the filesystem's
own overhead, and some room for what the system writes on its first boot.

Usage: rootfs-size.py --cpio-list LIST   (gen_init_cpio list: the rootfs
                                          copied from the initramfs)
       rootfs-size.py --tar ARCHIVE.tar.gz
"""
import os, sys, tarfile

BLOCK = 1024
FIRST_BOOT = 512        # KiB written on the first boot (keys, settings...)
OVERHEAD = 1.12         # inode tables, bitmaps, reserved blocks


def blocks(size):
    data = (size + BLOCK - 1) // BLOCK
    # one indirect block per 256 data blocks past the 12 direct ones
    return data + max(0, (data - 12 + 255) // 256)


def from_cpio_list(path):
    total = entries = 0
    for line in open(path):
        f = line.split()
        if not f:
            continue
        entries += 1
        if f[0] == 'file':
            total += blocks(os.path.getsize(f[2]))
        elif f[0] == 'dir':
            total += 1
    return total, entries


def from_tar(path):
    total = entries = 0
    with tarfile.open(path, 'r:gz') as t:
        for m in t:
            entries += 1
            if m.isreg():
                total += blocks(m.size)
            elif m.isdir():
                total += 1
            elif m.issym() and len(m.linkname) > 60:
                total += 1      # not a fast symlink
    return total, entries


kind, path = sys.argv[1:3]
total, entries = from_cpio_list(path) if kind == '--cpio-list' else from_tar(path)
# 128 byte inodes, at least one per entry
kib = (total + entries * 128 // BLOCK) * OVERHEAD + FIRST_BOOT
print(int(kib + 1023) // 1024 * 1024)
