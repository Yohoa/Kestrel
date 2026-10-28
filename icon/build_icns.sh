#!/bin/zsh
# Builds AppIcon.icns from the public-domain Yarrell kestrel engraving (see README.md).
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)
swiftc -O make_icon.swift -o "$T/make_icon"
"$T/make_icon" yarrell_kestrel_p52.jpg 600 620 1130 icon_1024.png 0.22 0.52
mkdir -p "$T/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon_1024.png --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o "$T/full.icns"
# iconutil stores 32-bit PNGs; repack with 256-colour ones (needs Pillow), else keep its output.
if python3 -c "import PIL" 2>/dev/null; then
  python3 pack_icns.py "$T/AppIcon.iconset" "$T/full.icns" ../AppIcon.icns
else
  cp "$T/full.icns" ../AppIcon.icns; echo "Wrote AppIcon.icns (Pillow missing, not shrunk)"
fi
