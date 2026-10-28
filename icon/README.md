# App icon

The icon is a public-domain wood engraving, not original artwork:

- **Work:** "The Kestrel, or Windhover", wood engraving in William Yarrell, *A History of British Birds*,
  vol. 1, p. 52 (London: John Van Voorst, 1843). Yarrell died in 1856; the engraving is in the public domain.
- **Scan:** Internet Archive item [`historyofbritish01yarr_0`](https://archive.org/details/historyofbritish01yarr_0)
  (University of Toronto, Fisher Library), page image `n57` → `yarrell_kestrel_p52.jpg`.
- **Processing** (`make_icon.swift`): crop to the perched bird, steep levels so the show-through from the
  reverse page turns white (a wood engraving is pure black ink; greys come from line density), print
  (multiply) onto a cream squircle.

Rebuild: `./build_icns.sh` → `../AppIcon.icns`.
