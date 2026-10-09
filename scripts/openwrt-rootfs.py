#!/usr/bin/env python3
"""Adapt an OpenWrt root filesystem archive to the TI-Nspire: drop the
kernel modules (built for another kernel) and the files listed in
REMOVE_LIST, and add or replace the files (and symbolic links) of an
overlay directory, keeping the ownership and modes of the archive.

Usage: openwrt-rootfs.py IN.tar.gz OUT.tar.gz OVERLAY_DIR REMOVE_LIST
"""
import gzip, io, os, sys, tarfile

src, dst, overlay, remove_list = sys.argv[1:5]


def norm(name):
    return './' + name.lstrip('./') if name not in ('.', './') else './'


extra = {}
for root, dirs, files in os.walk(overlay):
    dirs.sort()
    for f in sorted(files):
        path = os.path.join(root, f)
        extra[norm(os.path.relpath(path, overlay))] = path

remove = set()
for line in open(remove_list):
    line = line.split('#', 1)[0].strip()
    if line:
        remove.add(norm(line))

dropped = 0
with tarfile.open(src, 'r:gz') as tin, \
        open(dst, 'wb') as raw, \
        gzip.GzipFile(fileobj=raw, mode='wb', compresslevel=9, mtime=0) as gz, \
        tarfile.open(fileobj=gz, mode='w', format=tarfile.GNU_FORMAT) as tout:
    for m in tin:
        name = norm(m.name)
        if name.startswith('./lib/modules/') and name != './lib/modules/':
            dropped += 1
            continue
        if name in remove:
            remove.discard(name)
            continue
        if name in extra and not os.path.islink(extra[name]):
            path = extra.pop(name)
            data = open(path, 'rb').read()
            m.size = len(data)
            m.mode = 0o755 if os.access(path, os.X_OK) else 0o644
            m.type = tarfile.REGTYPE
            tout.addfile(m, io.BytesIO(data))
            continue
        tout.addfile(m, tin.extractfile(m) if m.isreg() else None)
    for name, path in extra.items():
        if os.path.islink(path):
            ti = tarfile.TarInfo(name)
            ti.type, ti.linkname = tarfile.SYMTYPE, os.readlink(path)
            ti.uid, ti.gid, ti.mtime, ti.mode = 0, 0, 0, 0o777
            tout.addfile(ti)
            continue
        data = open(path, 'rb').read()
        ti = tarfile.TarInfo(name)
        ti.size, ti.uid, ti.gid, ti.mtime = len(data), 0, 0, 0
        ti.mode = 0o755 if os.access(path, os.X_OK) else 0o644
        tout.addfile(ti, io.BytesIO(data))
if remove:
    sys.exit(f'not in the archive: {" ".join(sorted(remove))}')
print(f'openwrt rootfs: {dropped} module files dropped, '
      f'{os.path.getsize(dst)} bytes')
