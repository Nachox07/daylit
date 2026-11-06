"""Packs PNG files into one .ico (Windows Vista and later read PNG entries). Usage: ico.py out.ico a.png b.png …"""
import struct, sys

out, pngs = sys.argv[1], sys.argv[2:]
blobs = [open(p, "rb").read() for p in pngs]
head = struct.pack("<HHH", 0, 1, len(blobs))
offset = 6 + 16 * len(blobs)
entries = b""
for b in blobs:
    w, h = struct.unpack(">II", b[16:24])  # from the PNG IHDR chunk
    entries += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
open(out, "wb").write(head + entries + b"".join(blobs))
