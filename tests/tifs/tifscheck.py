#!/usr/bin/env python3
"""Read a real Touchpad's TI-Nspire filesystem out of a raw flash dump
(nspire-flashdump, or a Firebird flash image of it), the way the hardware
showed it works, independently of the kernel driver:

FlashFX: units of 64 pages; the header (page 0) holds the region's client
address (0x10), erase count (0x14), sequence number within the region
(0x1c), the number of units FlashFX uses (0x20), the unit the region goes on
with (0x24) and a checksum (0x36). Pages: allocation info 0x4000|index for
data, 0x5ff0 for a discard record (bitmap of the region's pages). Order: by
sequence number, then page.

Reliance: MAST, META (higher counter), index file, inodes, indirect blocks
named by index, directory entries in 16-byte units.

Usage: tifscheck.py FLASH [--files OUT.json] [--compare BEFORE.json
                     [--allow PATH]...] [--extract PATH DEST]
"""
import argparse, hashlib, json, struct, sys
from collections import Counter, defaultdict

R = 528
BASE = 0x200000 // 512
PPU = 64
ap = argparse.ArgumentParser()
ap.add_argument('flash')
ap.add_argument('--files', help='write the files and their md5 here')
ap.add_argument('--compare', help='files of another dump (or a mkfsimage.py manifest): '
                'report the changes')
ap.add_argument('--allow', action='append', default=[], help='a file that may change')
ap.add_argument('--extract', nargs=2, metavar=('PATH', 'DEST'))
ap.add_argument('--block', nargs=2, metavar=('PATH', 'N'), help='where block N of a file is')
ap.add_argument('--state', nargs=2, metavar=('PATH', 'OUT'), help='dump units, map and the block list of PATH (pickle)')
args = ap.parse_args()
d = open(args.flash, 'rb').read()
errors = 0


def err(msg):
    global errors
    errors += 1
    print('ERROR', msg)


def page(p):
    o = (BASE + p) * R
    return d[o:o + 512], d[o + 512:o + 528]


# Unit headers
h0, _ = page(0)
NU = struct.unpack_from('<I', h0, 0x20)[0]
RP = struct.unpack_from('<H', h0, 0x2c)[0] * struct.unpack_from('<H', h0, 0x32)[0]
units = {}
for u in range(NU):
    data, sp = page(u * PPU)
    if sp[0:2] != b'\xe2\x48':
        if data == b'\xff' * 512 and sp == b'\xff' * 16:
            print('unit %d free' % u)
            continue
        err('unit %d: no header' % u)
        continue
    if sum(data[:0x36]) & 0xffff != struct.unpack_from('<H', data, 0x36)[0]:
        err('unit %d: header checksum' % u)
    f = struct.unpack_from('<IIIIII', data, 0x10)
    if f[4] != NU:
        err('unit %d: unit count %d' % (u, f[4]))
    units[u] = dict(region=f[0] // 512 // RP, erase=f[1], seq=f[3], next=f[5])
byreg = defaultdict(list)
for u, i in units.items():
    byreg[i['region']].append(u)
for r, us in byreg.items():
    seqs = [units[u]['seq'] for u in us]
    if len(seqs) != len(set(seqs)):
        err('region %d: sequence numbers repeat' % r)
newest = {r: max(us, key=lambda u: units[u]['seq']) for r, us in byreg.items()}
nexts = Counter(units[n]['next'] for n in newest.values())
for r, n in newest.items():
    x = units[n]['next']
    if x >= NU:
        err('region %d: next unit %d past the end' % (r, x))
    elif x in newest.values():
        pass    # the TI-Nspire OS does name such units
    elif nexts[x] > 1:
        print('note: unit %d is next of %d regions' % (x, nexts[x]))

# Pages: copies and discard records, per region in order
ev = defaultdict(list)
for u, i in units.items():
    for p in range(1, PPU):
        data, sp = page(u * PPU + p)
        a = struct.unpack_from('<H', sp)[0]
        if a == 0xffff:
            continue
        if sp[2] != (~(sp[0] ^ sp[1])) & 0xff:
            err('u%d p%d: allocation check' % (u, p))
            continue
        if a == 0x5ff0:
            ev[i['region']].append((i['seq'], p, 'D', data))
        elif a >> 12 == 4 and (a & 0xfff) < RP:
            ev[i['region']].append((i['seq'], p, 'C', (u, p, a & 0xfff)))
        else:
            err('u%d p%d: allocation %04x' % (u, p, a))
m = {}
ndisc = 0
for r, es in ev.items():
    es.sort(key=lambda e: (e[0], e[1]))
    state = {}
    for seq, p, k, x in es:
        if k == 'C':
            state[x[2]] = x[:2]
        else:
            ndisc += 1
            for j in range(RP):
                if (x[j // 8] >> (j % 8)) & 1:
                    state[j] = None
    for j, v in state.items():
        if v:
            m[r * RP + j] = v


def blk(b):
    c = m.get(b)
    return page(c[0] * PPU + c[1])[0] if c else b'\xff' * 512


# Reliance
mast = blk(0)[0x40:]
assert mast[:4] == b'MAST', 'no MAST'
metas = [blk(struct.unpack_from('<I', mast, 0x10 + 4 * i)[0]) for i in range(2)]
meta = max((x for x in metas if x[:4] == b'META'), key=lambda x: struct.unpack_from('<I', x, 4)[0])


def inode_data(b):
    ino = blk(b)
    assert ino[:4] == b'INOD', 'block %d: not an inode' % b
    size = struct.unpack_from('<I', ino, 8)[0]
    mode = struct.unpack_from('<I', ino, 0x28)[0] & 3
    if mode == 0:
        return ino[0x40:0x40 + size]
    ptrs = list(struct.unpack_from('<112I', ino, 0x40))
    for level in range(mode - 1):
        nxt = []
        for p in ptrs:
            if p == 0xffffffff:
                break
            nb = blk(struct.unpack_from('<I', table, 4 * p)[0])
            want = b'DBLI' if level < mode - 2 else b'INDI'
            assert nb[:4] == want and struct.unpack_from('<I', nb, 4)[0] == p, \
                'index %d: not its %s' % (p, want)
            nxt += struct.unpack_from('<112I', nb, 0x40)
        ptrs = nxt
    n = (size + 511) // 512
    global last_blocks
    last_blocks = ptrs[:n]
    return b''.join(blk(p) for p in ptrs[:n])[:size]


table = None
table = inode_data(struct.unpack_from('<I', meta, 8)[0])
assert table[:4] == b'INDX'


def by_index(i):
    return struct.unpack_from('<I', table, 4 * i)[0]


ok = bad = 0
for i in range(2, len(table) // 4):
    b = by_index(i)
    if b in (0, 0xffffffff):
        continue
    h = blk(b)[:8]
    if h[:4] in (b'INOD', b'INDI', b'DBLI') and struct.unpack_from('<I', h, 4)[0] == i:
        ok += 1
    else:
        bad += 1
if bad:
    err('%d index entries lead elsewhere' % bad)

files = {}


def walk(idx, path):
    dd = inode_data(by_index(idx))
    pos = 0
    while pos + 16 <= len(dd) and dd[pos] == 0x80:
        length, nl = struct.unpack_from('<I', dd, pos + 3)[0], struct.unpack_from('<H', dd, pos + 7)[0]
        attr, ci = dd[pos + 9], struct.unpack_from('<I', dd, pos + 11)[0]
        name = b''.join(dd[pos + 16 * (k + 1) + 2:pos + 16 * (k + 2)]
                        for k in range((nl + 13) // 14))[:nl].decode('utf-16-le')
        if attr & 2:
            walk(ci, path + '/' + name)
        else:
            files[path + '/' + name] = inode_data(by_index(ci))
        pos += length


walk(2, '')
print('%d units in %d regions, %d logical pages, %d discard records; %d index entries ok; %d files'
      % (len(units), len(byreg), len(m), ndisc, ok, len(files)))
md5 = {p: hashlib.md5(x).hexdigest() for p, x in files.items()}
if args.files:
    json.dump(md5, open(args.files, 'w'), indent=1, sort_keys=True)
if args.compare:
    before = json.load(open(args.compare))
    for p in sorted(set(before) | set(md5)):
        if before.get(p) != md5.get(p):
            print('changed' if p in before and p in md5 else 'only before' if p in before
                  else 'only after', p)
            if p not in args.allow:
                err('%s changed' % p)
if args.block:
    # the file's inode again, for its block list
    def find(idx, path, want):
        dd = inode_data(by_index(idx)); pos = 0
        while pos + 16 <= len(dd) and dd[pos] == 0x80:
            length, nl = struct.unpack_from('<I', dd, pos + 3)[0], struct.unpack_from('<H', dd, pos + 7)[0]
            attr, ci = dd[pos + 9], struct.unpack_from('<I', dd, pos + 11)[0]
            name = b''.join(dd[pos + 16 * (k + 1) + 2:pos + 16 * (k + 2)] for k in range((nl + 13) // 14))[:nl].decode('utf-16-le')
            if path + '/' + name == want: return ci
            if attr & 2 and want.startswith(path + '/' + name + '/'): return find(ci, path + '/' + name, want)
            pos += length
    ci = find(2, '', args.block[0]); inode_data(by_index(ci))
    b = last_blocks[int(args.block[1])]
    r, j = divmod(b, RP)
    print('block %s of %s: volume block %d, region %d index %d; latest copy %s' % (args.block[1], args.block[0], b, r, j, m.get(b)))
    for u, i in sorted(units.items(), key=lambda x: x[1]['seq']):
        if i['region'] != r: continue
        for p in range(1, PPU):
            data, sp = page(u * PPU + p); a = struct.unpack_from('<H', sp)[0]
            if a == 0x4000 | j: print('  copy u%d p%d seq %d erase %d: %s' % (u, p, i['seq'], i['erase'], data[:8].hex()))
            if a == 0x5ff0 and (data[j // 8] >> (j % 8)) & 1: print('  discard u%d p%d seq %d' % (u, p, i['seq']))
if args.state:
    import pickle
    def find2(idx, path, want):
        dd = inode_data(by_index(idx)); pos = 0
        while pos + 16 <= len(dd) and dd[pos] == 0x80:
            length, nl = struct.unpack_from('<I', dd, pos + 3)[0], struct.unpack_from('<H', dd, pos + 7)[0]
            attr, ci = dd[pos + 9], struct.unpack_from('<I', dd, pos + 11)[0]
            name = b''.join(dd[pos + 16 * (k + 1) + 2:pos + 16 * (k + 2)] for k in range((nl + 13) // 14))[:nl].decode('utf-16-le')
            if path + '/' + name == want: return ci
            if attr & 2 and want.startswith(path + '/' + name + '/'): return find2(ci, path + '/' + name, want)
            pos += length
    inode_data(by_index(find2(2, '', args.state[0])))
    nf = {}
    for u in units:
        n = 1
        while n < PPU and struct.unpack_from('<H', page(u * PPU + n)[1])[0] != 0xffff: n += 1
        disc = sum(1 for p in range(1, n) if struct.unpack_from('<H', page(u * PPU + p)[1])[0] == 0x5ff0)
        nf[u] = (n, disc)
    pickle.dump(dict(units=units, map=m, nf=nf, blocks=last_blocks, RP=RP, NU=NU), open(args.state[1], 'wb'))
if args.extract:
    open(args.extract[1], 'wb').write(files[args.extract[0]])
print('OK' if not errors else '%d ERRORS' % errors)
sys.exit(1 if errors else 0)
