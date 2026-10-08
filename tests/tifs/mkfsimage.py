#!/usr/bin/env python3
"""Build a synthetic TI-Nspire internal filesystem (FlashFX Pro + Reliance)
following the Hackspire documentation, and write it into the "filesystem"
partition of a Firebird flash image (raw pages: data followed by spare).

The points the documentation leaves open are parameters (see tifs_spec.md).
The image contains /documents/linux/rootfs.img.tns as linuxloader2 creates it
(every 4 KiB chunk tagged), plus a few other files, older copies of pages and
a unit caught in the middle of a reclaim, which the reader has to resolve.
"""
import argparse, ctypes, os, random, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
_ham = ctypes.CDLL(os.path.join(HERE, 'libhamming.so'))
_ham.ecc_sw_hamming_calculate.argtypes = [ctypes.c_char_p, ctypes.c_uint, ctypes.c_char_p, ctypes.c_bool]

TAG_CHUNK = 4096
TAG_MAGIC = b'NSPLXIMG'
UNIT_MAGIC = 0x48E2


def hamming(data, step, sm):
    out = ctypes.create_string_buffer(3)
    _ham.ecc_sw_hamming_calculate(bytes(data), step, out, sm)
    return out.raw


class Geometry:
    """FlashFX units are 64 pages (Goplat: 937 units of 64 pages on a
    classic, i.e. two erase blocks each); 16 units of 61 client pages make
    a region of 976 logical pages."""
    def __init__(self, model):
        if model == 'cx':
            self.page, self.oob = 2048, 64
            self.part_offset, self.part_pages = 0x400000 // 2048, (0x8000000 - 0x400000) // 2048
        else:
            self.page, self.oob = 512, 16
            self.part_offset, self.part_pages = 0x200000 // 512, (0x2000000 - 0x200000) // 512
        self.ppb = 64                         # pages per FlashFX unit
        self.client = 61                      # logical pages per unit
        self.per_region = 16                  # units per region
        self.region_pages = self.client * self.per_region   # 976
        self.raw = self.page + self.oob
        self.units = self.part_pages // self.ppb


class Params:
    """The details the documentation leaves open, as used for this image."""
    alloc_off = 0          # spare offset of the allocation info (Goplat: 0)
    ecc_sm = False         # data ECC: 256 byte Hamming, this byte order
    # per 512 bytes of data (one 16 byte spare section): 4 byte fields holding
    # the ECC of the second and of the first 256 byte half (Goplat: 8-B, C-F)
    ecc_offsets = (8, 12)


def spare_for(geo, prm, alloc, data, used=True):
    """Spare area of a page: per 512 byte section, 16 bytes."""
    spare = bytearray(b'\xff' * geo.oob)
    b0, b1 = alloc & 0xff, alloc >> 8
    b2 = ~(b0 ^ b1) & 0xff
    b3 = (b0 * 7 + b1 * 13 + b2 * 31) & 0xff     # stands in for the unknown code
    spare[prm.alloc_off:prm.alloc_off + 4] = bytes([b0, b1, b2, b3])
    for sec in range(geo.page // 512):
        base = sec * 16
        if used:
            spare[base + 4:base + 8] = b'\xff\xff\xff\x0f'
        first, second = data[sec * 512:sec * 512 + 256], data[sec * 512 + 256:sec * 512 + 512]
        spare[base + prm.ecc_offsets[0]:base + prm.ecc_offsets[0] + 3] = hamming(second, 256, prm.ecc_sm)
        spare[base + prm.ecc_offsets[1]:base + prm.ecc_offsets[1] + 3] = hamming(first, 256, prm.ecc_sm)
    return bytes(spare)


def unit_header(geo, client_address, erase_count, seq, lnu_total, spare_units):
    """Layout from Goplat's description."""
    h = bytearray(b'\xff' * geo.page)
    h[0:16] = b'\xcc\xddDL_FS4.00' + b'\xff' * 5
    struct.pack_into('<IIIIIII', h, 0x10, client_address, erase_count, 0x5a, seq, 0x1234abcd,
                     lnu_total, spare_units)
    struct.pack_into('<HHHHHH', h, 0x2c, geo.page, geo.per_region, 0, geo.ppb, geo.client,
                     geo.ppb - 1)
    struct.pack_into('<H', h, 0x38, sum(h[0:0x38]) & 0xffff)
    return bytes(h)


class Reliance:
    """Lay out a Reliance volume over a logical byte space."""

    def __init__(self, size, bs):
        self.bs, self.nblocks = bs, size // bs
        self.blocks = {}
        self.next = 8                  # 0: MAST, 1-2: META, 3: IMAP
        self.inodes = {}               # index -> inode block
        self.next_index = 3

    def alloc(self, n=1):
        b = self.next
        self.next += n
        if self.next > self.nblocks:
            raise SystemExit('filesystem full')
        return b

    def put(self, b, data):
        assert len(data) <= self.bs
        self.blocks[b] = bytes(data) + b'\x00' * (self.bs - len(data))

    def write_data(self, data):
        """Store data, return (mode, pointer area content)."""
        bs = self.bs
        inline_max = bs - 0x40
        ptrs_per_inode = (bs - 0x40) // 4
        ptrs_per_block = (bs - 4) // 4
        if len(data) <= inline_max:
            return 0, data
        nblk = (len(data) + bs - 1) // bs
        first = self.alloc(nblk)
        for i in range(nblk):
            self.put(first + i, data[i * bs:(i + 1) * bs])
        blocks = list(range(first, first + nblk))
        if nblk <= ptrs_per_inode:
            return 1, struct.pack('<%dI' % nblk, *blocks)
        indis = []
        for i in range(0, nblk, ptrs_per_block):
            b = self.alloc()
            chunk = blocks[i:i + ptrs_per_block]
            self.put(b, b'INDI' + struct.pack('<%dI' % len(chunk), *chunk))
            indis.append(b)
        if len(indis) <= ptrs_per_inode:
            return 2, struct.pack('<%dI' % len(indis), *indis)
        dblis = []
        for i in range(0, len(indis), ptrs_per_block):
            b = self.alloc()
            chunk = indis[i:i + ptrs_per_block]
            self.put(b, b'DBLI' + struct.pack('<%dI' % len(chunk), *chunk))
            dblis.append(b)
        assert len(dblis) <= ptrs_per_inode
        return 3, struct.pack('<%dI' % len(dblis), *dblis)

    def inode(self, index, data, is_dir=False, block=None):
        mode, area = self.write_data(data)
        b = block if block is not None else self.alloc()
        hdr = bytearray(0x40)
        hdr[0:4] = b'INOD'
        struct.pack_into('<IQQQQHH', hdr, 4, index, len(data), 1700000000000, 1700000000000,
                         1700000000000, mode | (0x10 if is_dir else 0), 1)
        self.put(b, bytes(hdr) + area)
        self.inodes[index] = b
        return b

    @staticmethod
    def dirent(name, index, is_dir):
        """As on a real TI-Nspire: 0x80, a checksum (?), the length of the
        entry (u32 at 3, a multiple of 16), the length of the name (u16 at
        7), attributes (8: in use, 2: directory) at 9, the inode index (u32
        at 11), 01 00 at 16, then the UTF-16 name at 18."""
        n = name.encode('utf-16-le')
        length = (18 + len(n) + 15) // 16 * 16
        e = bytearray(18)
        e[0] = 0x80
        struct.pack_into('<I', e, 3, length)
        struct.pack_into('<H', e, 7, len(n))
        e[9] = 0x1 | (0x2 if is_dir else 0)
        struct.pack_into('<I', e, 11, index)
        struct.pack_into('<H', e, 16, 1)
        return bytes(e) + n + b'\x00' * (length - 18 - len(n))

    def tree(self, node):
        """node: dict name -> bytes (file) or dict (directory): the root
        directory, which is index 2."""
        return self._tree(node, 2)

    def _tree(self, node, index):
        entries = b''
        for name, child in node.items():
            ci = self.next_index
            self.next_index += 1
            if isinstance(child, dict):
                self._tree(child, ci)
                entries += self.dirent(name, ci, True)
            else:
                self.inode(ci, child)
                entries += self.dirent(name, ci, False)
        self.inode(index, entries, is_dir=True)
        return index

    def finish(self):
        # Index file (index 1): 'INDX' then the inode block of every index
        top = max(self.inodes) + 1
        indx = bytearray(b'INDX' + b'\x00' * (4 * (top - 1)))
        for idx, blk in self.inodes.items():
            struct.pack_into('<I', indx, 4 * idx, blk)
        index_block = self.inode(1, bytes(indx))
        # rewrite once more so the index file lists itself
        struct.pack_into('<I', indx, 4, index_block)
        self.inode(1, bytes(indx), block=index_block)
        mast = bytearray(self.bs)
        mast[0x40:0x44] = b'MAST'
        struct.pack_into('<HHIIIIQI', mast, 0x44, 1, 1, self.bs, self.nblocks, 1, 2,
                         1700000000, 1)
        self.put(0, mast)
        for copy, counter in ((1, 7), (2, 6)):
            meta = bytearray(64)
            meta[0:4] = b'META'
            struct.pack_into('<IIIIIIII', meta, 4, counter, index_block, self.next, 3, 3,
                             self.nblocks - self.next, self.next, 0)
            self.put(copy, meta)
        self.put(3, b'IMAP')
        return self.blocks


def tagged_image(size, payload=None):
    """As linuxloader2 creates it: every chunk tagged, the last one marked,
    and the payload, if any, after the tags (see rootimg.c)."""
    img = bytearray(size)
    chunks = size // TAG_CHUNK
    for i in range(chunks - 1):
        struct.pack_into('<8sII', img, i * TAG_CHUNK, TAG_MAGIC, i, 0)
    struct.pack_into('<8sII', img, (chunks - 1) * TAG_CHUNK, b'NSPLXEND', chunks, 1)
    if payload is not None:
        per = TAG_CHUNK - 16
        if 2 + (len(payload) + per - 1) // per > chunks:
            sys.exit('the image is too small for the payload')
        struct.pack_into('<8sII', img, 16, b'NSPLXPAY', len(payload), 0)
        for n, off in enumerate(range(0, len(payload), per)):
            part = payload[off:off + per]
            img[(n + 1) * TAG_CHUNK + 16:(n + 1) * TAG_CHUNK + 16 + len(part)] = part
    return bytes(img)


def build(args):
    geo, prm = Geometry(args.model), Params()
    rnd = random.Random(args.seed)
    spare_units = 8
    # Enough regions for the data, leaving units for rewrites and spares
    regions = (geo.units - spare_units) // geo.per_region - 2
    lnu_total = regions * geo.per_region
    logical_size = regions * geo.region_pages * geo.page

    rel = Reliance(logical_size, args.block_size)
    files = {
        'documents': {
            'linux': {args.image_name: (open(args.image_file, 'rb').read() if args.image_file
                                        else tagged_image(args.image_kib * 1024,
                                                          open(args.payload, 'rb').read()
                                                          if args.payload else None)),
                      'readme.tns': b'hello from the TI side\n'},
            'Examples': {'graph.tns': bytes(rnd.getrandbits(8) for _ in range(9000))},
        },
        'phoenix': {'syst': {'settings': b'\x01\x02\x03' * 100}},
    }
    rel.tree(files)
    blocks = rel.finish()

    # Logical pages of the Reliance volume
    logical = {}
    for b, data in blocks.items():
        off = b * rel.bs
        for i in range(0, rel.bs, geo.page):
            page_no, inpage = divmod(off + i, geo.page)
            buf = bytearray(logical.get(page_no, b'\xff' * geo.page))
            chunk = data[i:i + geo.page]
            buf[inpage:inpage + len(chunk)] = chunk
            logical[page_no] = bytes(buf)

    # Physical layout: logical units spread over shuffled physical units
    phys_units = list(range(geo.units))
    rnd.shuffle(phys_units)
    raw = bytearray(b'\xff' * (geo.part_pages * geo.raw))

    def write_page(unit, idx, data, alloc):
        p = unit * geo.ppb + idx
        raw[p * geo.raw:p * geo.raw + geo.page] = data
        raw[p * geo.raw + geo.page:(p + 1) * geo.raw] = spare_for(geo, prm, alloc, data)

    seq = 1000000           # above the stale units made for --free-units
    free = list(phys_units)
    region_units = {}

    def new_unit(region, erase_count=3):
        nonlocal seq
        unit = free.pop(0)
        seq += 1
        write_page(unit, 0, unit_header(geo, region * geo.region_pages * geo.page, erase_count,
                                        seq, lnu_total, spare_units), UNIT_MAGIC)
        region_units.setdefault(region, []).append(unit)
        return unit

    for region in range(regions):
        unit, nxt = new_unit(region), 1
        for idx in range(geo.region_pages):
            page_no = region * geo.region_pages + idx
            if page_no not in logical:
                continue
            copies = [logical[page_no]]
            if rnd.random() < 0.08:
                copies.insert(0, bytes(b ^ 0x5a for b in logical[page_no]))   # stale copy
            for data in copies:
                if nxt == geo.ppb:
                    unit, nxt = new_unit(region), 1
                write_page(unit, nxt, data, 0x4000 | idx)
                nxt += 1

    # Region 0 in the middle of a reclaim: a newer unit (higher sequence
    # number) holding the latest copies of only part of its pages
    unit = new_unit(0, erase_count=4)
    present = [i for i in range(geo.region_pages) if i in logical][:5]
    for n, idx in enumerate(present):
        write_page(unit, 1 + n, logical[idx], 0x4000 | idx)

    # Leave only --free-units free units: the others get filled with stale
    # copies (sequence numbers below every real unit), so writers have to
    # reclaim them.
    stale_seq = 1
    while args.free_units is not None and len(free) > args.free_units:
        unit = free.pop()
        region = rnd.randrange(regions)
        stale_seq += 1
        # Old copies of pages that have newer ones: stale, like the result
        # of earlier rewrites
        used = [lp for lp in logical if lp // geo.region_pages == region]
        if not used:
            region = rnd.choice([lp // geo.region_pages for lp in logical])
            used = [lp for lp in logical if lp // geo.region_pages == region]
        hdr = unit_header(geo, region * geo.region_pages * geo.page, 2, stale_seq, lnu_total,
                          spare_units)
        write_page(unit, 0, hdr, UNIT_MAGIC)
        for p in range(1, geo.ppb):
            lp = rnd.choice(used)
            write_page(unit, p, bytes(rnd.getrandbits(8) for _ in range(geo.page)),
                       0x4000 | (lp % geo.region_pages))

    with open(args.flash, 'r+b') as f:
        f.seek(geo.part_offset * geo.raw)
        f.write(raw)

    # What the TI side holds, for checking that writers left it alone
    import hashlib, json

    def walk(node, prefix):
        for name, child in node.items():
            path = prefix + '/' + name
            if isinstance(child, dict):
                yield from walk(child, path)
            else:
                yield path, hashlib.md5(child).hexdigest()
    with open(args.flash + '.manifest.json', 'w') as f:
        json.dump(dict(walk(files, '')), f, indent=1)

    print(f'{args.model}: {geo.units} units of {geo.ppb} pages, {regions} regions, '
          f'{len(free)} free units, '
          f'Reliance block {rel.bs}, {rel.next} blocks used, image {len(files["documents"]["linux"][args.image_name]) // 1024} KiB, '
          f'{len(logical)} logical pages')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('model', choices=['cx', 'tp', 'clp'])
    ap.add_argument('flash')
    ap.add_argument('--image-kib', type=int, default=8192)
    ap.add_argument('--image-name', default='rootfs.img.tns',
                    help='name of the image file in /documents/linux')
    ap.add_argument('--image-file', help='contents of the image file (default: tagged, '
                    'as linuxloader2 creates it)')
    ap.add_argument('--payload', help='file the loader writes into the new image')
    ap.add_argument('--block-size', type=int, default=0)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--free-units', type=int, default=None)
    args = ap.parse_args()
    if not args.block_size:
        args.block_size = 2048 if args.model == 'cx' else 512
    build(args)


if __name__ == '__main__':
    main()
