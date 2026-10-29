# Changes

Newest first. Dates are when the change was made.

## Planned

- **Import your own LUTs**: choose a folder of `.cube` files again, with a way to set the input space (camera log) of a LUT whose name doesn't say it. Overrides kept outside the app (never inside it).

## Unreleased (since 1.5.3)

- **⌥+ / ⌥− (and the status bar's − / +) stopped at +0.34 EV**: only the step was rounded, not the new value, so after the first press each one added 0.01. Fixed (the bug was there since 1.1); ⅓ EV steps now land on 0.33, 0.67, 1.00.
- **Exposure Stats** is hidden by default (Panels menu or F4 shows it; Reset panel layout hides it again), and it is as tall as its rows: a fixed height cut the B row off.
- **Sharp fitted photos on big screens**: the fitted picture used to be decoded at a quarter of the photo's size whatever the screen, so on a 4K display a 10 MP APS-C crop (3936 × 2624 → 984 px) was enlarged 2.6×. It is now decoded at the size the picture area needs (a quarter at least, full size at most), and again when the window grows. Measured on a 24 MP ARW: 75 ms instead of 57 ms for a 4K-sized picture. Slider drags render at half that size so they stay fluid.
- **Splitters**: the gaps beside the side columns are as narrow as the window's edge (3 pt instead of 8), while the handle in them is wider than it looks (18 pt, reaching into the picture side) for a finger or a Pencil. Two fingers on a trackpad, or a finger on an iPad as a Sidecar display, drag a handle too.
- **A handle above the filmstrip**: drag it to make the filmstrip taller or shorter (remembered); double-click for the usual height. The thumbnails grow and shrink with it, and are read sharper (760 px instead of 360) so a tall strip and large grid cells stay crisp.
- **Notices** have a solid frosted backing (clear glass let a bright photo or the LUT thumbnails show through the words), and the "27 LUTs loaded" notice no longer appears at every launch.
- The **floating side column** (pointing at a folded side) has the same rounded corners as the picture and the panels.
- The status bar is a little lower (34 pt instead of 40).
- **Stars in the status bar can be dragged**: drag along them to set the rating where you let go, or off the left end of the first star to clear it (no stars). A click still sets that many.
- **Panels in their own window** no longer have an empty band under the title bar: the panel's header sits beside the window buttons.
- **Status bar in a narrow window**: the white-balance menu no longer slides under the stars; buttons and menus keep their size, the file name shortens, and the image size, photo count and status text step aside whole when there is no room (no cut-off "6…" or a count wrapped onto two lines).

## 1.5.3 — 2026-10-29

- **No more freezes on network shares**: clicking a folder, stepping between photos, launching with History / Favourites on a share, rating, labelling and Move to _Rejected all stay responsive. Measured on SMB: a 6.7 s freeze while browsing and 6 s at launch are gone (steps 0–1 ms). Causes: paths were "standardised" while drawing (a file-system check per call, a network round trip each), history paths were turned into URLs with a check each, and Move to _Rejected waited on the main thread for pending sidecar writes.
- Ratings, labels and rejects show at once; on a share the sidecar is written afterwards (the old value comes back if that fails). The folder being opened shows a spinner in Folders until its photos are listed.
- The update window was too narrow for its four buttons, so their labels were cut short; it is wider now.
- **Network drives connect again on their own**: opening a folder on a share that went away (a favourite, History, the last folder at launch, a drop) connects the share first, with no Finder window, using the server address remembered from when it was last mounted and the keychain password (macOS asks only if it has none). The favourite row says "Connecting…" meanwhile.
- **Favorite folders** that can't be reached (a network drive not connected, a drive unplugged, a folder moved) are greyed with an orange sign; clicking one says "Not connected" (or "Folder not found") in the row for a moment instead of opening nothing. Checked in the background (2 s limit), again on every mount / unmount and on each click.
- **⌘C copies the edited photo as HEIC** by default: 10-bit, a few MB (4.3 MB for a 24 MP photo) instead of a ~96 MB TIFF. Settings ▸ Export ▸ "⌘C copies the edited photo as" chooses HEIC (default), JPG (8-bit, opens anywhere) or TIFF (lossless, now without the unused alpha channel).
- **⌘C also puts the file on the clipboard** (`<photo>_<look>.heic`, kept in ~/Library/Caches/Kestrel/Clipboard): pasting in Finder makes a real file, Mail and Messages attach it, image apps take the picture. Copies older than a day (or beyond 300 MB) are cleared at launch.

## 1.5.2 — 2026-10-28

- **JPGs without a RAW**: a JPG is shown when no RAW of the same name sits next to it (RAW + JPG pairs still show once, as the RAW). Exposure, white balance (with Pick neutral and Auto WB), contrast and looks work on it; "As shot" is the picture as it is (6500 K / 0); highlight recovery does not apply.
- **Move to _Rejected** takes a RAW's JPG along (⌘Z brings both back). White balance is copied and pasted only RAW to RAW or JPG to JPG (a RAW's Kelvin is the light, a JPG's a shift of the picture).
- **Every RAW format macOS reads**: besides ARW, RAF and DNG, now Canon CR2 / CR3 / CRW, Nikon NEF / NRW, Olympus ORF, Panasonic RW2 / RAW, Leica RWL, Pentax PEF, Samsung SRW, Sony SRF / SR2, Olympus ORI, Hasselblad 3FR / FFF, Phase One IIQ, Epson ERF, Leaf MOS, Minolta MRW and Kodak DCR (a .raw only when it is a Panasonic / Leica file) (which camera models decode is up to macOS). Sort & Filter ▸ File type lists the types in the folder; Finder's Open With offers Kestrel for any RAW file. A cell shows its file type only when the folder mixes types.

## 1.5.1 — 2026-10-28

- **Favorite folders**: the header star is filled when the folder on screen is a favourite, and a click removes it again.
- **Hover tips** on nearly every control: status bar, panel headers, Develop / White Balance rows, filter rows, LUT cells, folder rows, Export and Settings.
- **Folders**: the tree was empty when no drive or network share was mounted (the home folder was never listed); fixed, and ↻ lists it too if it hadn't been.

## 1.5 — 2026-10-28

- **Grid**: clicking a photo no longer centres it (so a double-click's second click no longer lands on another photo): a photo in full view stays put, one cut off at the top or bottom edge scrolls just enough to show it whole; moving with the keys does the same.
- **Filmstrip**: a click works the same way (no jump to the centre; a cell cut off at the edge scrolls just enough); keys and swipes still keep the current photo centred.
- The app is filed under **Photography**.

## 1.4 — 2026-10-28

- **Updates**: Kestrel ▸ Check for Updates…, and a check once a day (Settings ▸ Updates). A new version is downloaded from the GitHub release, checked against its SHA-256 and the signing certificate, put in place and relaunched.
- **Welcome** screen on the first launch and a **tip** at later launches (Close / Don't Show Again; Help menu).
- **Fewer surprises** (from a review of what could confuse a new user):
  - Trying looks no longer saves them: the LUT panel starts in Preview, and the default look is Base. Sony's picture profiles are called "Sony PP1 Movie" … "Sony PP10 HLG".
  - Batch export uses each photo's own look by default (or the ticked looks, in Export settings); export settings are kept across launches; the buttons are called Export As… and Quick Export, and say why when there is nothing to export.
  - Rating and label notices appear once the .xmp is written, and a failed write says so; rejecting a photo that the filter then hides says how to see it, and the count shows "N rejected hidden".
  - Closing a panel says how to get it back; panel names match the Panels menu.
  - Help (F1 / ⌘K) lists the menu shortcuts too, what acts on the photo or the selection, Esc, ⌘N and the files Kestrel writes.
  - RAWs and folders open from Finder (Open With, the Dock icon) into the one window.
  - A recorded shortcut that a menu already uses is refused.
  - The sidecar backup is now `.xmp.kestrel-backup`.
- **Folders**: Rename… in a folder's right-click menu (not for the top-level folders and drives); favourites, history, expanded rows and the folder being browsed follow the new name.
- **LUTs**: only the 27 built-in LUTs for now (their names say which camera log they expect, so there is nothing to set); choosing a LUT folder of your own, and setting a LUT's input by hand, will come back later.

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
