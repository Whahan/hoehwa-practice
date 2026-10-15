# -*- coding: utf-8 -*-
"""Zips <staging>\\<root-name> into <zip>. Python's zipfile sets the UTF-8 flag for non-ASCII names,
so Korean file names survive Windows Explorer / PowerShell extraction.

    python make_zip.py <staging_parent_dir> <root_name> <out.zip>
    root_name "." zips the contents of <staging_parent_dir> at the zip root (update packages).
"""
import os
import sys
import time
import zipfile

parent, root_name, out = sys.argv[1], sys.argv[2], sys.argv[3]
src = parent if root_name == "." else os.path.join(parent, root_name)
prefix = "" if root_name == "." else root_name + "/"
STORE = {".whl", ".zip", ".pt", ".pth", ".bin", ".safetensors", ".png", ".jpg", ".gz"}

files = []
for dp, dn, fns in os.walk(src):
    dn.sort()
    for fn in sorted(fns):
        files.append(os.path.join(dp, fn))
if os.path.exists(out):
    os.remove(out)
t0 = time.time()
total = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
    # directories first (keeps empty ones, e.g. nothing here today, but harmless)
    for f in files:
        arc = prefix + os.path.relpath(f, src).replace("\\", "/")
        ext = os.path.splitext(f)[1].lower()
        method = zipfile.ZIP_STORED if ext in STORE else zipfile.ZIP_DEFLATED
        z.write(f, arc, compress_type=method)
        total += os.path.getsize(f)
print("zipped %d files, %.1f MB -> %.1f MB in %.0fs" % (len(files), total / 1e6, os.path.getsize(out) / 1e6, time.time() - t0))
