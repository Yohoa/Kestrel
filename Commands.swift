import SwiftUI
import AppKit

// FastRawViewer's menu bar (File / View / Adjust / Select / XMP Metadata / Panels / Help) plus a Looks menu for
// LUT switching. Shortcuts follow the FastRawViewer 2 manual, with Ctrl → ⌘ and Alt → ⌥ on the Mac.
// Keys without a modifier (G, O, K, ⇧K, A, W, Z, F …) are handled by the key monitor in Keys.swift so they never
// fire while typing in a text field; their menu items show the key in the title.

extension Model {
    // MARK: exposure (⌥+ / ⌥−, ⌥⌘ = big step, A reset / restore, ⇧A auto)

    func stepExposure(up: Bool, big: Bool) {
        let step = big ? bigEVStep : smallEVStep
        nudgeExposure(up ? step : -step)
        status = String(format: "Exposure %+.2f EV", exposure)
    }

    /// A: back to 0 EV; pressing A again brings the previous value back (FastRawViewer behaviour).
    func resetOrRestoreExposure() {
        guard let url = current else { return }
        let ev = currentState.ev
        if ev != 0 {
            exposureMemory[url] = ev
            editCurrent { $0.ev = 0 }
            status = "Exposure reset to 0 (A again restores \(String(format: "%+.2f", ev)) EV)"
        } else if let old = exposureMemory[url] {
            editCurrent { $0.ev = old }
            exposureMemory[url] = nil
            status = String(format: "Exposure restored to %+.2f EV", old)
        } else { return }
        refreshAll()
    }

    // MARK: contrast (K / ⇧K)

    /// K / ⇧K: half a grade per press (the Develop slider goes down to 0.1).
    func changeContrast(_ delta: Float) {
        guard current != nil else { return }
        editCurrent { $0.contrast = max(-5, min(5, (($0.contrast + delta) * 10).rounded() / 10)) }
        status = "Contrast " + String(format: "%+.1f", currentState.contrast)
        refreshAll()
    }

    var contrast: Double {
        get { Double(currentState.contrast) }
        set { adjust { $0.contrast = max(-5, min(5, Float((newValue * 10).rounded() / 10))) } }
    }

    // MARK: view

    func toggleFullScreen() { mainWindow?.toggleFullScreen(nil) }
    func zoomToFit() { unzoomAnimated() }
    func zoomTo100() { zoom(to: 1.0) }

    /// Tab: hide every panel; Tab again brings back exactly what was shown.
    func toggleHideAllPanels() {
        layoutStore.peekLeft = false; layoutStore.peekRight = false
        // Every panel already closed by hand: there is nothing for Tab to hide, and doing nothing looks broken.
        // Bring the default view back instead (every panel, in the current arrangement, both sides unfolded).
        if panelsBeforeHideAll == nil, !Panel.allCases.contains(where: { $0 != .filmstrip && shown($0) && !isDetached($0) }) {
            hiddenPanels = []
            layoutStore.setCollapsed(left: true, false)
            layoutStore.setCollapsed(left: false, false)
            status = "No panels were shown: all panels back (Tab hides them)"
            return
        }
        if let saved = panelsBeforeHideAll {
            hiddenPanels = saved
            panelsBeforeHideAll = nil
        } else {
            panelsBeforeHideAll = hiddenPanels
            hiddenPanels = Set(Panel.allCases.map(\.rawValue))
        }
    }

    // MARK: looks / LUT switching

    /// [ / ]: previous / next look in the order the LUT panel shows them.
    func stepLook(_ delta: Int) {
        let list = visibleLooks
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == ppID } ?? 0
        let next = list[(i + delta + list.count) % list.count]
        chooseLook(next.id)
        status = "Look: \(next.title)"
        notify(.lookStep, "Look: \(next.title)", icon: "camera.filters")
    }

    /// { / }: previous / next favourite look.
    func stepFavoriteLook(_ delta: Int) {
        let favs = looks.filter { isFavorite($0.id) }
        guard !favs.isEmpty else { status = "No favourite looks yet — press L on a look"; return }
        let i = favs.firstIndex { $0.id == ppID } ?? (delta > 0 ? -1 : 0)
        let next = favs[(i + delta + favs.count) % favs.count]
        chooseLook(next.id)
        status = "Favourite look: \(next.title)"
        notify(.lookStep, "Favourite look: \(next.title)", icon: "star")
    }

    /// ⌃1 … ⌃9: favourite look n; ⌃0: Base.
    func favoriteLook(_ n: Int) {
        if n == 0 { chooseLook(0); status = "Look: Base"; return }
        let favs = looks.filter { isFavorite($0.id) }
        guard favs.indices.contains(n - 1) else { status = "No favourite look #\(n)"; return }
        chooseLook(favs[n - 1].id)
        status = "Favourite look #\(n): \(favs[n - 1].title)"
    }

    var favoriteLookList: [PPLook] { looks.filter { isFavorite($0.id) } }

    /// \: before / after — flips between the current look and Base without saving anything.
    func toggleBeforeAfter() {
        if let back = lookBeforeCompare {
            ppID = back
            lookBeforeCompare = nil
            status = "After: \(look.title)"
        } else {
            guard ppID != 0 else { return }
            lookBeforeCompare = ppID
            ppID = 0
            status = "Before (Base) — press \\ again for the look"
        }
        refreshPreview()
        if zoomed { refreshZoom(force: true) }
    }

    // MARK: files

    func openFolder(recursive: Bool) {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.message = recursive ? "Choose a folder (its subfolders are included)" : "Choose a folder"
        guard p.runModal() == .OK, let u = p.url else { return }
        load([u], recursive: recursive)
    }

    func reloadFolder() { if let f = currentFolder { load([f]) } }
    func revealCurrent() { if let c = current { revealInFinder(c) } }
}

// MARK: - Menus

@MainActor
struct PanelCommands: Commands {
    @ObservedObject var m: Model

    /// The About panel's thanks (the README says the same at more length).
    static let credits: NSAttributedString = {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let out = NSMutableAttributedString()
        func add(_ text: String, link: String? = nil, bold: Bool = false) {
            var a: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize) : small,
                                                    .foregroundColor: NSColor.labelColor]
            if let link, let u = URL(string: link) { a[.link] = u }
            out.append(NSAttributedString(string: text, attributes: a))
        }
        add("Thanks to\n", bold: true)
        add("Raw Alchemy", link: "https://github.com/shenmintao/raw-alchemy")
        add(" by shenmintao: the RAW → camera log → LUT pipeline and the Auto EV metering modes it is modelled on.\n")
        add("V-Log Alchemy", link: "https://github.com/shenmintao/V-Log-Alchemy")
        add(" by shenmintao: the built-in V-Log LUTs (Apache-2.0, licence in the app's Resources/LUTs).\n")
        add("FastRawViewer", link: "https://www.fastrawviewer.com")
        add(": the workflow and shortcuts it imitates.\n")
        add("Icon: William Yarrell, A History of British Birds (1843), public domain.")
        let p = NSMutableParagraphStyle(); p.alignment = .center
        out.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: out.length))
        return out
    }()

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Kestrel") { NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.credits]) }
            Button("Check for Updates…") { m.checkForUpdates() }
        }
        // File
        CommandGroup(replacing: .newItem) {
            Button("New Window") { m.openNewInstance() }.keyboardShortcut("n", modifiers: .command)
                .help("Another Kestrel, independent of this one")
            Divider()
            Button("Open…") { m.open() }.keyboardShortcut("o", modifiers: .command)
            Button("Open Folder…") { m.openFolder(recursive: false) }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open Folder with Subfolders…") { m.openFolder(recursive: true) }.keyboardShortcut("o", modifiers: .option)
            Menu("Recent Folders") {
                ForEach(m.recentInputs, id: \.self) { u in
                    Button(u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent) { m.load([u]) }
                }
                Divider()
                Button("Clear Recent Folders") { m.clearHistory() }
            }
            Toggle("Include Subfolders", isOn: Binding(get: { m.includeSubfolders },
                                                       set: { m.includeSubfolders = $0; m.includeSubfoldersChanged() }))
            Divider()
            Button("Reload Current Folder") { m.reloadFolder() }.keyboardShortcut(functionKey(4), modifiers: [.command, .shift])
            Button("Reveal in Finder") { m.revealCurrent() }.keyboardShortcut("f", modifiers: .command)
            Button("Move to \(Model.rejectedFolderName)") { m.moveToRejected() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])          // FastRawViewer: ⇧⌘⌫
            Divider()
            Button("Export As…") { m.exportCurrent() }.keyboardShortcut("e", modifiers: .command)
            Button("Quick Export") { m.quickExport() }
            Button(m.exportAllTitle) { m.exportAll() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Settings…") { m.sheet = .export }
        }

        // View
        CommandGroup(before: .toolbar) {
            Button(m.viewMode == .grid ? "Switch to Single Image    G" : "Switch to Image Grid    G") { m.toggleGrid() }
            Button("Full Screen    F") { m.toggleFullScreen() }
            Divider()
            Button("Zoom In") { m.zoomStep(1) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { m.zoomStep(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("Fit to Window") { m.zoomToFit() }.keyboardShortcut("0", modifiers: .command)
            Button("Actual Pixels (100%)") { m.zoomTo100() }.keyboardShortcut("1", modifiers: .command)
            Button("Zoom to Subject (Toggle)    Z") { m.zoomToSubject() }
            Button("Smart Zoom (Toggle)    ⇧Z") { m.smartZoomMiddle() }
            Divider()
            Toggle("Overexposure Display    O", isOn: Binding(get: { m.showOver }, set: { _ in m.toggleOver() }))
            Toggle("Underexposure Display    U", isOn: Binding(get: { m.showUnder }, set: { _ in m.toggleUnder() }))
            Divider()
            Picker("Theme", selection: Binding(get: { m.theme }, set: { m.theme = $0 })) {
                Text("System").tag(0)
                Text("Dark").tag(1)
                Text("Light").tag(2)
            }
            Button("Toggle Dark / Light") {
                let dark = m.theme == 1 || (m.theme == 0 && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                m.theme = dark ? 2 : 1
            }.keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
        }

        // Adjust
        CommandMenu("Adjust") {
            Button("Increase Exposure") { m.stepExposure(up: true, big: false) }.keyboardShortcut("=", modifiers: .option)
            Button("Decrease Exposure") { m.stepExposure(up: false, big: false) }.keyboardShortcut("-", modifiers: .option)
            Button("Increase Exposure (Big Step)") { m.stepExposure(up: true, big: true) }.keyboardShortcut("=", modifiers: [.option, .command])
            Button("Decrease Exposure (Big Step)") { m.stepExposure(up: false, big: true) }.keyboardShortcut("-", modifiers: [.option, .command])
            Button("Auto Exposure Correction    ⇧A") { m.autoExposure(scope: m.current.map { [$0] } ?? []) }
            Button("Reset / Restore Exposure    A") { m.resetOrRestoreExposure() }
            Divider()
            Button("Increase Contrast    K") { m.changeContrast(0.5) }
            Button("Decrease Contrast    ⇧K") { m.changeContrast(-0.5) }
            Divider()
            Button("Toggle White Balance    W") { m.cycleWB() }
            Menu("White Balance") {
                ForEach(WBPreset.all) { p in Button(p.name) { m.applyWBPreset(p) } }
                Divider()
                Button("Pick Neutral…") { m.pickingWB = true }
            }
            Toggle("Highlight Recovery", isOn: Binding(get: { m.highlightRecovery }, set: { m.highlightRecovery = $0; m.developChanged() }))
                .disabled(m.current.map(BitmapPhoto.isBitmap) ?? false)        // a JPG has no highlights to recover
            Divider()
            Button("Copy Edited Photo    ⌘C") { m.copyImageToClipboard() }
            ForEach(ShortcutAction.allCases) { a in
                Button(a.menuTitle + (m.shortcuts.shortcut(a).map { "    " + $0.display } ?? "")) { m.perform(a) }
            }
            Button("Paste Settings    ⌘V") { m.pasteSettings() }
            Divider()
            Button("Rotate Left    ⌘[") { m.rotate(-1) }.disabled(m.current == nil)
            Button("Rotate Right    ⌘]") { m.rotate(1) }.disabled(m.current == nil)
            Button("Reset Image Rendering to Defaults") { m.resetAdjustments(); m.developChanged() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        // Select
        CommandMenu("Select") {
            Button("Select All Shown    ⌘A") { m.selectAll() }
            Button("Invert Selection    ⌘I") { m.invertSelection() }.disabled(m.files.isEmpty)
            Button("Deselect All    Esc") { m.clearSelection() }.disabled(!m.hasGroup)
            Divider()
            Button(m.currentIsSelected ? "Deselect and Move to Next    ⌘D" : "Select and Move to Next    ⌘D") { m.toggleCurrentSelection(thenStep: 1) }
            Button("Move to Previous and (De)select") { m.step(-1); m.toggleCurrentSelection() }
            Divider()
            Toggle("Filter On    V", isOn: Binding(get: { m.filter.enabled }, set: { m.filter.enabled = $0 }))
            Button("Reset Filter") { m.resetFilter() }
            Divider()
            Button("Next Photo    Space / →") { m.step(1) }
            Button("Previous Photo    ⇧Space / ←") { m.step(-1) }
            Button("First Photo    Home") { m.goFirst() }
            Button("Last Photo    End") { m.goLast() }
        }

        // XMP Metadata (star marking, labels)
        CommandMenu("XMP Metadata") {
            if m.hasGroup && m.viewMode == .grid { Button("Rate / label \(m.selection.count) selected photos") {}.disabled(true); Divider() }
            ForEach(1...5, id: \.self) { i in
                Button(String(repeating: "★", count: i)) { m.setRating(i) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i))), modifiers: .option)
            }
            Button("No Rating") { m.setRating(0) }.keyboardShortcut("0", modifiers: .option)
            Button("Reject    X") { m.setRating(-1) }
            Divider()
            ForEach(Array(labelNames.prefix(4).enumerated()), id: \.offset) { i, name in
                Button("Label \(name)") { m.setLabel(name) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 6))), modifiers: .option)
            }
            Button("Label Purple") { m.setLabel("Purple") }          // FastRawViewer has no key for it either
            Button("Clear Label") { m.setLabel(nil) }
        }

        // Looks (LUT switching)
        CommandMenu("Looks") {
            Button("Next Look    ]") { m.stepLook(1) }
            Button("Previous Look    [") { m.stepLook(-1) }
            Button("Next Favourite Look    }") { m.stepFavoriteLook(1) }
            Button("Previous Favourite Look    {") { m.stepFavoriteLook(-1) }
            Button("Before / After (Base)    \\") { m.toggleBeforeAfter() }
            Button(m.isFavorite(m.ppID) ? "Remove Current Look from Favourites    L" : "Add Current Look to Favourites    L") { m.toggleFavoriteLook(m.ppID) }
            Divider()
            Button("Base") { m.favoriteLook(0) }.keyboardShortcut("0", modifiers: .control)
            ForEach(Array(m.favoriteLookList.prefix(9).enumerated()), id: \.offset) { i, look in
                Button("★ \(look.title)") { m.favoriteLook(i + 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .control)
            }
        }

        // Panels
        CommandMenu("Panels") {
            ForEach(Panel.allCases) { p in
                Toggle(p.title, isOn: Binding(get: { m.shown(p) }, set: { _ in m.toggle(p) }))
                    .keyboardShortcut(functionKey(p.fKey), modifiers: p.needsShift ? .shift : [])
            }
            Divider()
            Button("Hide All Panels    Tab") { m.toggleHideAllPanels() }
            Button("Show All Panels") { m.setAllPanels(visible: true) }
            Divider()
            Button(m.layoutStore.leftCollapsed ? "Unfold Left Sidebar" : "Fold Left Sidebar") { m.layoutStore.toggleCollapsed(left: true) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button(m.layoutStore.rightCollapsed ? "Unfold Right Sidebar" : "Fold Right Sidebar") { m.layoutStore.toggleCollapsed(left: false) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Divider()
            Button("Save Layout…") { m.layoutStore.saveCurrent(from: m) }
            Menu("Layouts") {
                ForEach(m.layoutStore.presetNames, id: \.self) { n in Button(n) { m.layoutStore.applyPreset(n, to: m) } }
                Divider()
                Menu("Delete") {
                    ForEach(m.layoutStore.presetNames, id: \.self) { n in Button(n) { m.layoutStore.deletePreset(n) } }
                }
            }
            .disabled(m.layoutStore.presetNames.isEmpty)
            Button("Reset Panel Layout") { m.layoutStore.reset(m) }
        }

        // Help
        CommandGroup(replacing: .help) {
            Button("Welcome to Kestrel") { m.sheet = .welcome }
            Button("Tips…") { m.sheet = .tips }
            Button("Keyboard Shortcuts") { m.sheet = .help }.keyboardShortcut("k", modifiers: .command)
        }
    }
}
