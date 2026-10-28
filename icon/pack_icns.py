#!/usr/bin/env python3
"""Shrinks an .iconset to 256-colour PNGs and packs them into an .icns by hand.

iconutil re-encodes every PNG as 32-bit RGBA, which for the noisy engraving costs
~1.9 MB; the palette PNGs look the same and pack to roughly a quarter of that.
The 16/32 px ARGB chunks iconutil writes are kept as they are.

usage: pack_icns.py AppIcon.iconset iconutil-output.icns out.icns   (needs Pillow)
"""
import io, struct, sys
from PIL import Image

iconset, ref, out = sys.argv[1:4]

# icns chunk type → iconset file
PNG_CHUNKS = {
    b"ic11": "icon_16x16@2x.png",
    b"ic12": "icon_32x32@2x.png",
    b"ic07": "icon_128x128.png",
    b"ic13": "icon_128x128@2x.png",
    b"ic08": "icon_256x256.png",
    b"ic14": "icon_256x256@2x.png",
    b"ic09": "icon_512x512.png",
    b"ic10": "icon_512x512@2x.png",
}

def palette_png(path):
    im = Image.open(path).convert("RGBA")
    q = im.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG)
    b = io.BytesIO()
    q.save(b, "PNG", optimize=True)
    return b.getvalue()

data = open(ref, "rb").read()
chunks, i = [], 8
while i < len(data):
    t, n = struct.unpack(">4sI", data[i:i + 8])
    body = data[i + 8:i + n]
    if t in PNG_CHUNKS:
        body = palette_png(f"{iconset}/{PNG_CHUNKS[t]}")
    chunks.append(struct.pack(">4sI", t, len(body) + 8) + body)
    i += n

payload = b"".join(chunks)
open(out, "wb").write(struct.pack(">4sI", b"icns", len(payload) + 8) + payload)
print(f"Wrote {out} ({(len(payload) + 8) // 1024} KB)")
