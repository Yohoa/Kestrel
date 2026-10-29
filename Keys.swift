import AppKit
import SwiftUI

// One keyboard layer for the main window and the torn-off panels. A local NSEvent monitor sees every key before
// SwiftUI's focus system, so shortcuts keep working after clicking a slider, a menu or a list. It stays out of the
// way while a text field is being edited, and in the Settings window, open/save panels and sheets.
// Default bindings follow FastRawViewer 2 (Ctrl → ⌘, Alt → ⌥ on the Mac); keys with ⌘ / ⌥ / ⌃ are menu shortcuts
// (Commands.swift), plain keys are handled here.

enum Shortcuts {
    static let groups: [(title: String, items: [(keys: String, text: String)])] = [
        ("Navigate", [
            ("← →  Space  ⇧Space", "Previous / next photo (follows the filter). In the grid: Space marks / unmarks the photo (⌘-click), ⇧Space selects the range up to it (⇧-click)"),
            ("Return", "Grid → the photo in single view; single view → back to the grid"),
            ("Swipe, flick", "Two fingers sideways, or a quick sideways drag, on the photo: previous / next"),
            ("Home  End", "First / last photo"),
            ("↑ ↓", "One row up / down in the grid"),
            ("G", "Image grid ↔ single image"),
            ("Double-click", "Open the photo in single view (grid)"),
            ("⌘O  ⌘⇧O  ⌥O", "Open files / folder / folder with subfolders"),
            ("⌘⇧F4", "Reload the current folder"),
            ("⌘F", "Reveal in Finder"),
            ("⇧⌘⌫", "Move to _Rejected (next to the RAW, with its .xmp; ⌘Z moves it back until you open another folder)"),
        ]),
        ("Rate, label, select", [
            ("1 – 5   (or ⌥1 – ⌥5)", "Star rating"),
            ("0   (or ⌥0)", "No rating"),
            ("X", "Reject / un-reject. Rejected photos are hidden while the filter is on (V shows them)"),
            ("6 – 9   (or ⌥6 – ⌥9)", "Label Red / Yellow / Green / Blue; again to clear"),
            ("Click  ⌘-click  ⇧-click  ⌘⇧-click", "Select this photo / add or remove one / a range / add a range"),
            ("⇧←  ⇧→   (⇧↑ ⇧↓ in the grid)", "Extend the selection"),
            ("⌘A  ⌘I  ⌘D", "Select every shown photo / invert / (de)select this one and go to the next"),
            ("What acts on what", "Ratings, labels and X: the photo on screen in single view, the selected photos in the grid. ⌘V, Apply to…, Copy WB to…, Auto EV ▸ Selection and Export: the selected photos anywhere. Sliders and develop keys: the photo on screen"),
        ]),
        ("Adjust", [
            ("⌥+  ⌥−", "Exposure up / down (small step; Settings)"),
            ("⌥⌘+  ⌥⌘−", "Exposure up / down (big step)"),
            ("Drag a value", "Up / down on a Develop or White Balance number (⌥ finer, ⇧ faster); double-click resets it"),
            ("⇧A", "Auto exposure correction"),
            ("A", "Exposure to 0; A again restores it"),
            ("K  ⇧K", "Contrast up / down by ½ grade (−5…+5; the Develop slider goes in 0.1)"),
            ("W", "Toggle white balance: As Shot → Daylight → Auto → Custom"),
            ("⌘⇧R", "Reset image rendering to defaults"),
            ("⌘C", "Copy the edited photo (full size, with its look, exposure and WB) to the clipboard as a file and a picture: HEIC, JPG or TIFF (Settings ▸ Export)"),
            ("⌥⌘C  ⌘V", "Copy all settings / paste the copied settings (only the parts copied; to the selection). Copy Develop, White Balance and LUT on their own: Settings ▸ Shortcuts"),
        ]),
        ("Looks / LUTs", [
            ("Click, double-click", "A click shows a look (in Preview mode nothing is saved); a double-click saves it to the photo on screen"),
            ("[  ]", "Previous / next look (LUT panel order)"),
            ("{  }   (⇧[  ⇧])", "Previous / next favourite look"),
            ("⌃1 – ⌃9", "Favourite look 1 – 9"),
            ("⌃0", "Base"),
            ("\\", "Before / after: flip between the look and Base"),
            ("L", "Add / remove the current look from the favourites"),
        ]),
        ("View", [
            ("Z, double-click", "Smart zoom: fit ↔ the smallest of 25/33/50/67/100 % that is ≥ 2 × the fit size (Settings); double-click zooms on that spot"),
            ("⌘1  ⌘0  ⌘+  ⌘−", "100 % / fit to window / next / previous zoom step"),
            ("Pinch, ⌥/⌘ + scroll", "Zoom at the pointer; or drag the Fit / % label in the status bar sideways"),
            ("O  U", "Over-exposure (red) / under-exposure (blue) display"),
            ("F", "Full screen"),
            ("Tab", "Hide all panels (point at the left / right edge to peek); Tab again shows them"),
            ("V", "Filter on / off"),
            ("F2 – F10, ⇧F7, ⇧F8", "Show / hide panels (⇧F8 = Sort & Filter); a panel closed with × stays closed until shown here or in the Panels menu"),
            ("⌥⌘[  ⌥⌘]", "Fold / unfold the left / right sidebar"),
            ("⇧⌘L", "Dark ↔ light"),
        ]),
        ("Esc", [
            ("Esc", "In this order: cancels picking a neutral grey, clears the selection, zooms back to fit, closes a sheet"),
        ]),
        ("Export, windows, help", [
            ("⌘E", "Export As…: this photo, to a place you choose"),
            ("⇧⌘E", "Export the shown or selected photos, each with its own look (Export settings: ⚙︎ in the status bar)"),
            ("Right-click ▸ Quick Export", "This photo, no dialog, into the Export settings' folder (a HEIC folder next to the RAW by default)"),
            ("⌘Z  ⇧⌘Z", "Undo / redo (ratings, labels, develop, looks, moves); the history starts again with each folder"),
            ("⌘N", "Another Kestrel window, a separate app of its own; both share the settings, and the one that quits last keeps its own"),
            ("⌘,", "Settings"),
            ("F1  ⌘K  ?", "This help"),
        ]),
        ("Files Kestrel writes", [
            ("photo.xmp", "Ratings, labels and Kestrel's settings, next to each RAW (Lightroom and FastRawViewer read it too)"),
            ("photo.xmp.kestrel-backup", "A one-time copy of a sidecar another program wrote, before Kestrel first changed it"),
            ("_Rejected/", "Photos moved there with ⇧⌘⌫"),
            ("HEIC/", "Exports, by default"),
        ]),
    ]
}

extension Model {
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) ? nil : event }
        }
        // A click anywhere outside the text field being edited ends the editing (AppKit only does that when the
        // click lands on something that takes focus itself); the click then goes on as usual.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let w = event.window, w.firstResponder is NSTextView else { return event }   // most clicks
            MainActor.assumeIsolated {
                if let editor = w.firstResponder as? NSTextView, editor.isFieldEditor,
                   let field = editor.delegate as? NSView,
                   !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    w.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    /// Top-row and keypad digit keys by position, so 0–9 work on AZERTY and other layouts too.
    private static let digitKeyCodes: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// Returns true when the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        guard let key = NSApp.keyWindow else { return false }

        // Our own sheets (export settings, help): Esc / F1 close them, everything else is left alone.
        if sheet != nil {
            guard e.keyCode == 53 || e.keyCode == 122 else { return false }
            if key === mainWindow || key.sheetParent === mainWindow { sheet = nil; return true }
            return false
        }
        let ours = key === mainWindow || panelWindows.values.contains { $0 === key }
        guard ours, key.attachedSheet == nil else { return false }
        if key.firstResponder is NSText { return false }               // typing in a text field

        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let shift = mods.contains(.shift)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""

        if let a = shortcuts.action(for: e) { perform(a); return true }       // set in Settings ▸ Shortcuts

        if mods == .command {
            switch ch {
            case "a": selectAll(); return true
            case "i": invertSelection(); return true
            case "d": toggleCurrentSelection(thenStep: 1); return true
            case "c": copyImageToClipboard(); return true                        // the edited photo itself
            case "v": pasteSettings(); return true
            default: return false                                       // ⌘O, ⌘F, ⌘1 … belong to the menus
            }
        }
        if mods.contains(.command) || mods.contains(.control) { return false }

        switch e.keyCode {
        case 123: if shift { extendSelection(-1) } else { step(-1) }; return true    // ← (⇧ extends the selection)
        case 124: if shift { extendSelection(1) } else { step(1) }; return true      // →
        case 125:                                                                     // ↓
            let d = viewMode == .grid ? gridColumns : 1
            if shift { extendSelection(d) } else { step(d) }; return true
        case 126:                                                                     // ↑
            let d = viewMode == .grid ? -gridColumns : -1
            if shift { extendSelection(d) } else { step(d) }; return true
        case 115: goFirst(); return true                                  // Home
        case 119: goLast(); return true                                   // End
        case 49:                                                          // Space / ⇧Space
            // grid: Space marks / unmarks the current photo (⌘-click), ⇧Space selects the range from the last marked
            // one to it (⇧-click); single view: next / previous (FRV)
            if viewMode == .grid, let c = current { click(c, command: !shift, shift: shift) } else { step(shift ? -1 : 1) }
            return true
        case 48: toggleHideAllPanels(); return true                       // Tab (FRV)
        case 36, 76:                                                      // Return / Enter: grid ↔ single view
            if viewMode == .grid { if let c = current { open(c) } } else { toggleGrid() }
            return true
        case 122: sheet = .help; return true                              // F1
        case 53:                                                           // Esc
            if pickingWB { pickingWB = false; return true }
            if !selection.isEmpty { clearSelection(); return true }
            if zoomed { toggleZoom(); return true }
            return false
        default: break
        }

        if e.characters == "?" { sheet = .help; return true }            // needs ⇧ on most layouts

        // Star marking and labels: 0–5 / 6–9, with or without ⌥ (FRV default is ⌥), by key position
        if mods.subtracting([.option, .shift]).isEmpty, let d = Self.digitKeyCodes[e.keyCode] {
            switch d {
            case 0...5: setRating(d)
            case 6: setLabel("Red")
            case 7: setLabel("Yellow")
            case 8: setLabel("Green")
            default: setLabel("Blue")
            }
            return true
        }
        if mods.contains(.option) { return false }                       // ⌥+ / ⌥− / ⌥O … are menu shortcuts

        switch (ch, shift) {
        case ("x", false): setRating(-1)
        case ("g", false): toggleGrid()
        case ("z", false): toggleZoom()
        case ("f", false): toggleFullScreen()
        case ("o", false): toggleOver()
        case ("u", false): toggleUnder()
        case ("k", false): changeContrast(0.5)                             // FRV: K
        case ("k", true): changeContrast(-0.5)                             // FRV: ⇧K
        case ("a", false): resetOrRestoreExposure()                       // FRV: A
        case ("a", true): autoExposure(scope: current.map { [$0] } ?? [])  // FRV: ⇧A, this photo (Develop ▸ Auto EV for a selection)
        case ("w", false): cycleWB()                                      // FRV: W
        case ("l", false): toggleFavoriteLook(ppID)
        case ("v", false):
            filter.enabled.toggle(); status = filter.enabled ? "Filter on" : "Filter off"
            notify(.filter, status + " · \(files.count) shown", icon: "line.3.horizontal.decrease.circle")
        case ("[", false): stepLook(-1)
        case ("]", false): stepLook(1)
        case ("{", _): stepFavoriteLook(-1)
        case ("}", _): stepFavoriteLook(1)
        case ("\\", false): toggleBeforeAfter()
        default: return false
        }
        return true
    }
}
