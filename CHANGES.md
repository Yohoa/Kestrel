# Changes

Newest first. Dates are when the change was made.

## 1.3 — 2026-10-28

- **Built-in LUTs**: the 27 V-Log Alchemy LUTs (Apache-2.0, licence included) come with the app, used when no LUT folder of your own is set; LUT panel gear › Built-in LUTs switches back to them. Same layout as a LUT folder, so looks saved in `.xmp` files are found in either.

## 1.2 — 2026-10-28

- **Copy and paste**
  - ⌘C copies the edited photo (full size, with its look, exposure and white balance).
  - Copy Develop, Copy White Balance, Copy LUT and Copy All Settings (⌥⌘C); ⌘V pastes only the parts that were copied, to the selection.
  - Settings › Shortcuts: set a shortcut for each copy action.
- **Grid**: a click selects at once (it used to wait for a possible double-click, ~0.3 s); marked photos show a clearer round badge.
- **LUT thumbnail menu**: Apply to Selected Photos.
- **Folders**: refresh button in the header.
- **Windows**: no window tabs; File › New Window (⌘N) opens another, independent Kestrel.
- **Touch and trackpad**
  - Swipe left / right on the photo to switch photos: two-finger swipe, Magic Mouse or three-finger swipe, and a quick sideways drag (Pencil or finger on a Sidecar iPad, or a mouse).
  - Drag a Develop value up / down to change it; drag the zoom indicator to zoom; two-finger scrolling over a value adjusts it.
  - ⌥ / ⌘ + scroll zooms the photo; bigger touch targets in the status bar.
  - The window can shrink to 760 × 560, so it fits an iPad used as a Sidecar display.
- **Right-click on the photo**: Rating, Label · Auto Exposure, Auto White Balance · Export (one click), Export As…, Copy Edited Photo · Undo, Redo · Move to _Rejected, Reveal in Finder.
- **Notices** where an action happened: below the photo (export, copy, rating, label, undo, auto exposure, white balance…) and in the LUT box (look saved, LUTs loaded or new, favourites, input space, mode). Each kind can be switched off in Settings › Notices.
- **LUT panel**
  - Preview / Apply / Per photo moved into the header as compact capitals.
  - Double-click a LUT to save it to the photo on screen.
  - Clicks now land on the right thumbnail (a tall photo's overflow used to catch them).
  - A LUT's input space is read-only when its file name says it; ⌥-click or right-click to override, "Use file name" to go back.
- **Copy WB to…** copies the numbers the photo on screen shows (an As Shot source used to reset the others to their own camera WB).
- **Tab** with every panel closed brings them all back; in full screen the Tab margins are narrower again.
- The one-time `.xmp` backup is made only for sidecars written by other programs.

## 1.1 — 2026-10-28

- **Auto EV metering rewritten from scratch**: same five modes (matrix, hybrid, average, center-weighted, highlight-safe) and lens-circle detection, new names in the menus.
- **Big folder trees**: photos appear while the scan is still running; metadata on network shares about 4× faster.
- **Slow storage** (network shares, external drives): files read in large chunks before decoding, the photo on screen first, thumbnails and EXIF cached locally; stepping on an SMB share about 1.2 s → 0.75 s per photo.
- **LUTs**
  - Preview / Apply / Per photo modes.
  - Each LUT's input space kept in `kestrel-lut-inputs.json` in the LUT folder.
  - A LUT whose path moved is found by file name.
- **Move to _Rejected** (⇧⌘⌫, undoable), next to each RAW with its `.xmp`.
- **Folders**
  - Network shares and external drives shown and refreshed on mount.
  - A gear menu sets how many levels of subfolders to include.
- **Zoom**: springy, smooth zoom back to fit; no freeze from 150–400 %.
- About panel and acknowledgements.

## Before 1.1 — 2026-10-26 to 2026-10-28

- First version as "ARWExport": RAW → 10-bit HEIC export with Sony picture-profile-style looks; renamed **Kestrel**, with an engraved kestrel icon.
- Scene-linear S-Log / HLG output and folders of `.cube` LUTs (RAW → camera log → LUT).
- FastRawViewer-style culling: ratings, labels, reject, Sort & Filter (including camera and lens), multi-selection, undo / redo; settings and ratings in standard `.xmp` sidecars.
- Develop: exposure, white balance (As Shot, Daylight, Auto, pick neutral), contrast, highlight recovery, Auto EV; histogram, exposure stats and clipping overlays.
- Panels that can be moved, resized, folded or opened in their own window; layout presets; Tab hides them all, with edge peeking; light and dark themes.
- Grid and filmstrip, trackpad pinch and smart zoom, full screen.
- Folder tree with a right-click menu, favourites and history.
- Two code reviews' worth of fixes, faster builds and narrower redraws.
