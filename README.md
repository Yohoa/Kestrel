# Kestrel

A native macOS RAW viewer and culling tool (SwiftUI + Core Image) for Sony ARW, Fujifilm RAF and DNG, with
10-bit HEIC export. It works the way FastRawViewer does: rate, label and reject from the keyboard, with ratings and
settings kept in standard `.xmp` sidecars that Lightroom and FastRawViewer read too.

## Features

- **Fast browsing**: the camera's embedded preview appears at once, then the real RAW render; neighbours are
  prefetched. Grid and filmstrip views, smart zoom with a springy animation, trackpad pinch and pan.
- **Looks**: Sony picture-profile-style looks, scene-linear S-Log / HLG output, and folders of `.cube` LUTs. The
  LUT panel has three modes: Preview (try a look on every photo), Apply (write it to the photo) and Per photo.
  Each LUT's input space (S-Log3, V-Log, F-Log2…) is read from its file name (`…_VLog`, `…SLog3…`); Develop
  then shows it read-only, so it can't be changed by accident. ⌥-click it, or use the LUT thumbnail's right-click
  menu, to set it by hand; "Use File Name" goes back. Only settings that differ from the file name are kept, in
  `kestrel-lut-inputs.json` in the LUT folder. A LUT whose name says nothing keeps a menu to choose its input.
- **Develop**: exposure, white balance, contrast, highlight recovery, auto EV with several metering modes,
  histogram and clipping overlays.
- **Culling**: star ratings, colour labels, reject, Move to `_Rejected` (⇧⌘⌫, undoable), Sort & Filter
  (including camera and lens), undo / redo for every edit.
- **Folders**: folder tree with network shares and external drives, subfolders to a chosen depth, favourites.
- **Slow storage**: on network shares and external drives, files are read in large chunks before decoding, the
  photo on screen is read first, and thumbnails and EXIF are cached locally.
- **Export**: 10-bit HEIC, one look or several per photo, optional sidecar copy.

## Building

Requires macOS 14 or later (highlight recovery needs macOS 26) and the Xcode command-line tools. There is no Xcode
project; `build.sh` compiles the sources with `swiftc` into `Kestrel.app` and signs it.

```sh
./build.sh
open Kestrel.app
```

`build.sh` signs with the local "Yohoa Studio" identity when it exists and ad hoc otherwise.

## Acknowledgements

- **[Raw Alchemy](https://github.com/shenmintao/raw-alchemy)** by shenmintao. Kestrel's LUT pipeline follows
  its approach: decode the RAW to scene-linear, convert it to the camera log gamut and curve a LUT was made for
  (S-Log3, V-Log, F-Log2…), then apply the creative LUT, so photo LUTs land as they do on video. Its set of
  Auto EV metering modes (matrix, hybrid, average, center-weighted, highlight-safe) is the model for Kestrel's.
  Thank you for working this out so carefully and sharing it. Kestrel contains no Raw Alchemy code.
- **[V-Log Alchemy](https://github.com/shenmintao/V-Log-Alchemy)** by shenmintao (Apache-2.0): the film and
  camera looks rebuilt as V-Log LUTs that Kestrel is used with. They are not included here.
- **[FastRawViewer](https://www.fastrawviewer.com)**: the culling workflow, panels and keyboard shortcuts Kestrel
  imitates. No code from it is used.
- **App icon**: "The Kestrel, or Windhover", a public-domain wood engraving from William Yarrell's
  *A History of British Birds* (1843); see `icon/README.md`.

## Licence

No licence has been chosen for Kestrel yet.

