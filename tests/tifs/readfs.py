#!/usr/bin/env python3
"""Read a TI-Nspire internal filesystem (FlashFX Pro + Reliance) out of a
Firebird flash image, independently of the kernel driver, following the
documentation (Goplat, Hackspire) and the conventions of mkfsimage.py.

Checks: unit header checksums, the ECC of every latest page copy, that every
file of the manifest still has its original contents, and prints the MD5 of
/documents/linux/rootfs.img.tns without its last 4 KiB chunk (what Linux
sees as /dev/tifs0).
"""
import argparse, ctypes, hashlib, json, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mkfsimage import Geometry, hamming, UNIT_MAGIC  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('model')
ap.add_argument('flash')
ap.add_argument('--image', default='/documents/linux/rootfs.img.tns')
ap.add_argument('--extract', help='also write the image file to this file')
args = ap.parse_args()
geo = Geometry(args.model)
raw = open(args.flash, 'rb').read()
part = raw[geo.part_offset * geo.raw:(geo.part_offset + geo.part_pages) * geo.raw]
errors = 0


def page(p):
    o = p * geo.raw
    return part[o:o + geo.page], part[o + geo.page:o + geo.raw]


# FlashFX
best = {}       # logical page -> (seq, phys)
units = 0
for u in range(geo.units):
    data, spare = page(u * geo.ppb)
    alloc = struct.unpack_from('<H', spare)[0]
    if alloc == 0xffff:
        continue
    if alloc != UNIT_MAGIC:
        print(f'unit {u}: unexpected header allocation info {alloc:#x}')
        errors += 1
        continue
    if sum(data[:0x38]) & 0xffff != struct.unpack_from('<H', data, 0x38)[0]:
        print(f'unit {u}: bad header checksum')
        errors += 1
        continue
    units += 1
    client, seq = struct.unpack_from('<I', data, 0x10)[0], struct.unpack_from('<I', data, 0x1c)[0]
    base = client // geo.page
    for i in range(1, geo.ppb):
        _, sp = page(u * geo.ppb + i)
        alloc = struct.unpack_from('<H', sp)[0]
        if alloc == 0xffff:
            continue
        if alloc & 0xf000 != 0x4000 or sp[2] != (~(sp[0] ^ sp[1])) & 0xff:
            print(f'unit {u} page {i}: bad allocation info {sp[:4].hex()}')
            errors += 1
            continue
        key = (seq, u * geo.ppb + i)
        lp = base + (alloc & 0xfff)
        if lp not in best or key > best[lp]:
            best[lp] = key

ecc_bad = 0
logical = {}
for lp, (_, p) in best.items():
    data, spare = page(p)
    for sec in range(geo.page // 512):
        d = data[sec * 512:(sec + 1) * 512]
        if spare[sec * 16 + 12:sec * 16 + 15] != hamming(d[:256], 256, False) or \
           spare[sec * 16 + 8:sec * 16 + 11] != hamming(d[256:], 256, False):
            ecc_bad += 1
    logical[lp] = data
if ecc_bad:
    print(f'{ecc_bad} sections with a wrong ECC')
    errors += 1


def read(off, n):
    out = bytearray()
    while n:
        lp, inp = divmod(off, geo.page)
        c = min(n, geo.page - inp)
        out += logical.get(lp, b'\xff' * geo.page)[inp:inp + c]
        off += c
        n -= c
    return bytes(out)


# Reliance
mast = read(0x40, 0x30)
assert mast[:4] == b'MAST'
bs = struct.unpack_from('<I', mast, 8)[0]
metas = [read(struct.unpack_from('<I', mast, 0x10 + 4 * i)[0] * bs, 64) for i in range(2)]
meta = max((m for m in metas if m[:4] == b'META'), key=lambda m: struct.unpack_from('<I', m, 4)[0])


def inode(block):
    b = read(block * bs, bs)
    assert b[:4] == b'INOD', block
    return b


def inode_data(ino):
    size, mode = struct.unpack_from('<I', ino, 8)[0], struct.unpack_from('<I', ino, 0x28)[0] & 3
    if mode == 0:
        return ino[0x40:0x40 + size]
    ptrs = list(struct.unpack_from('<%dI' % ((bs - 0x40) // 4), ino, 0x40))
    for level in range(mode - 1):
        nxt = []
        for p in ptrs:
            if p == 0xffffffff:
                break
            # indirect blocks are named by an index, like inodes
            b = read(struct.unpack_from('<I', table, 4 * p)[0] * bs, bs)
            assert b[:4] == (b'DBLI' if level < mode - 2 else b'INDI')
            # the inode's 0x40-byte header, then pointers
            nxt += struct.unpack_from('<%dI' % ((bs - 0x40) // 4), b, 0x40)
        ptrs = nxt
    nblk = (size + bs - 1) // bs
    return b''.join(read(p * bs, bs) for p in ptrs[:nblk])[:size]


index_ino = inode(struct.unpack_from('<I', meta, 8)[0])
table = inode_data(index_ino)
assert table[:4] == b'INDX'


def by_index(i):
    return inode(struct.unpack_from('<I', table, 4 * i)[0])


files = {}


def walk(ino, path):
    d = inode_data(ino)
    pos = 0
    while pos + 16 <= len(d) and d[pos] == 0x80:
        length, m = struct.unpack_from('<I', d, pos + 3)[0], struct.unpack_from('<H', d, pos + 7)[0]
        attr, idx = d[pos + 9], struct.unpack_from('<I', d, pos + 11)[0]
        # 7 characters in each unit after the first, past its count of units left
        name = b''.join(d[pos + 16 * (k + 1) + 2:pos + 16 * (k + 2)]
                        for k in range((m + 13) // 14))[:m].decode('utf-16-le')
        child = by_index(idx)
        if attr & 2:
            walk(child, path + '/' + name)
        else:
            files[path + '/' + name] = inode_data(child)
        pos += length


walk(by_index(2), '')

manifest = json.load(open(args.flash + '.manifest.json'))
for path, md5 in manifest.items():
    if path == args.image:
        continue
    if path not in files:
        print(f'{path}: missing')
        errors += 1
    elif hashlib.md5(files[path]).hexdigest() != md5:
        print(f'{path}: CHANGED')
        errors += 1
img = files[args.image]
if args.extract:
    with open(args.extract, 'wb') as f:
        f.write(img)
print(f'{units} units, {len(best)} logical pages, {len(files)} files; '
      f'{len(manifest) - 1} TI files checked')
print(f'image md5 (without the last chunk): {hashlib.md5(img[:-4096]).hexdigest()}')
print(f'last chunk tag: {img[-4096:-4080].hex()}')
print('OK' if not errors else f'{errors} ERRORS')
sys.exit(1 if errors else 0)
