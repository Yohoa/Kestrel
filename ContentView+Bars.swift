import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Filmstrip, status bar and sheets.

extension ContentView {
    // MARK: filmstrip (the mouse wheel scrolls it sideways)

    /// Everything but the thumbnail takes 48 pt of the strip's height (name, borders, margins): 128 → 80 pt pictures.
    var filmstrip: some View {
        FilmstripView(m: m, thumbs: thumbs, menu: { AnyView(photoMenu($0)) },
                      imageHeight: CGFloat(m.layoutStore.filmstripHeight - 48).rounded())
    }

    // MARK: status bar

    /// Also redrawn on its own when the status line or the export progress changes (they don't redraw the window).
    var statusBar: some View { Observing(m.statusState) { _ in statusBarContent } }

    /// Status-bar buttons are small to look at but get a target the size of a fingertip (Sidecar, trackpad).
    func hitTarget<V: View>(_ v: V, width: CGFloat = 22) -> some View {
        v.frame(minWidth: width, minHeight: 30).contentShape(Rectangle())
    }

    var statusBarContent: some View {
        HStack(spacing: 9) {
            Button { m.step(-1) } label: { hitTarget(Image(systemName: "chevron.left")) }
                .buttonStyle(.plain).disabled((m.currentIndex ?? 0) == 0).help("Previous photo (←)").layoutPriority(2)
            Text(m.currentIndex.map { "\($0 + 1)/\(m.files.count)" } ?? "–/\(m.files.count)")
                .font(.system(size: 12).monospacedDigit()).lineLimit(1).fixedSize().frame(minWidth: 50)
                .help("Position of this photo among the shown photos")
            Button { m.step(1) } label: { hitTarget(Image(systemName: "chevron.right")) }
                .buttonStyle(.plain).disabled(m.currentIndex.map { $0 >= m.files.count - 1 } ?? true).help("Next photo (→)").layoutPriority(2)
            Text(m.current?.lastPathComponent ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .help(m.current?.path ?? "")
            // shown whole or not at all (a cut-off "6000x…" reads as nonsense)
            ViewThatFits(in: .horizontal) {
                Text(m.imageSize).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Color.clear.frame(width: 0)
            }
            .layoutPriority(-1)
                .help("Size of the photo in pixels")
            Divider()
            Button { m.nudgeExposure(NSEvent.modifierFlags.contains(.shift) ? -1 : -1.0 / 3) } label: { hitTarget(Image(systemName: "minus.square")) }.buttonStyle(.plain)
                .help("Exposure −⅓ EV (⇧-click: −1 EV)")
            Text(String(format: "%+.2f EV", m.exposure)).font(.system(size: 12).monospacedDigit()).lineLimit(1).fixedSize().layoutPriority(2)
                .help("Exposure of this photo. A sets it to 0 (A again restores it), ⇧A meters it automatically")
            Button { m.nudgeExposure(NSEvent.modifierFlags.contains(.shift) ? 1 : 1.0 / 3) } label: { hitTarget(Image(systemName: "plus.square")) }.buttonStyle(.plain)
                .help("Exposure +⅓ EV (⇧-click: +1 EV)")
            Menu("\(m.wbIsCustom ? "WB" : "As shot") \(Int(m.temperature))K/\(Int(m.tint))") {
                ForEach(WBPreset.all) { p in Button(p.name) { m.applyWBPreset(p) } }
                Divider()
                Button("Pick neutral…") { m.pickingWB = true }
            }
            .fixedSize()
            .layoutPriority(2)        // a fixed-size view that is offered less draws past its slot, over its neighbours
            .help("White balance in Kelvin / tint: pick a preset, or a neutral spot on the photo (W switches As Shot → Daylight → Auto → Custom)")
            Divider()
            ratingControls.fixedSize().layoutPriority(2)
            Divider()
            indicator("O", on: m.showOver) { m.toggleOver() }.help("Show blown highlights in red (O)").layoutPriority(2)
            indicator("U", on: m.showUnder) { m.toggleUnder() }.help("Show crushed shadows in blue (U)").layoutPriority(2)
            // follows a pinch or drag live (the zoom state is its own observable)
            Observing(m.zoomState) { _ in indicator(m.zoomLabel, on: m.zoomed) { m.toggleZoom() } }
                .overlay {
                    // reaches 14 pt above the bar and a little to the sides: at the window's bottom edge a finger
                    // (Sidecar) is hard to place on the small label itself
                    DragToAdjust(cursor: .resizeLeftRight, onBegin: {}, onChange: { p, mods in m.dragZoom(p, mods) },
                                 onEnd: { m.dragZoomEnded() }, onClick: { m.toggleZoom() }, onDoubleClick: { m.zoomToFit() })
                        .padding(.top, -14).padding(.horizontal, -6).padding(.bottom, -4)
                }
                .help("Drag left / right to zoom (⌥ finer, ⇧ faster). Click: fit ↔ smart zoom, double-click: fit. ⌘+ / ⌘− step, ⌘1 = 100 %, ⌘0 = fit")
                .layoutPriority(2)
            if m.currentIsSelected {
                Text("Sel").font(.caption.bold()).foregroundStyle(.red).help("The photo on screen is part of the selection")
            }
            if m.hasGroup {
                Text("\(m.selection.count) selected").font(.caption).foregroundStyle(Color.accentColor)
                    .help("⌘V, Apply to…, Copy WB to… and Export act on these; ratings and labels too in the grid (in single view they act on the photo on screen). Esc clears.")
            }
            Divider()
            if m.exporting {
                ProgressView(value: m.progress).frame(width: 80).help("Export progress")
                Button("Cancel") { m.cancelExport() }.controlSize(.small).help("Stop the export (photos already written are kept)")
            }
            Button { withAnimation(LayoutStore.spring) { m.toggle(.filmstrip) } } label: {
                Image(systemName: "film").foregroundStyle(m.shown(.filmstrip) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).disabled(m.viewMode == .grid)
            .help(m.shown(.filmstrip) ? "Fold the filmstrip (F6)" : "Show the filmstrip (F6)")
            Button { m.toggleGrid() } label: { Image(systemName: m.viewMode == .grid ? "photo" : "square.grid.2x2") }
                .buttonStyle(.plain).help(m.viewMode == .grid ? "Single photo (G)" : "Grid view (G)")
            if m.viewMode == .grid { Slider(value: $m.gridCell, in: 120...360).frame(width: 90).help("Thumbnail size") }
            // the long form, the bare count, or nothing: never wrapped onto two lines
            ViewThatFits(in: .horizontal) {
                Text("\(m.shownPhotos.count)/\(m.library.count)\(m.filter.isActive ? " filtered" : "")\(m.rejectedHidden > 0 ? " · \(m.rejectedHidden) rejected hidden" : "")")
                    .lineLimit(1).fixedSize()
                Text("\(m.shownPhotos.count)/\(m.library.count)").lineLimit(1).fixedSize()
                Color.clear.frame(width: 0)
            }
                .font(.caption.monospacedDigit())
                .foregroundStyle(m.filter.isActive ? Color.accentColor : .secondary)
                .help(m.filter.isActive ? "Shown / all photos in the folder. Sort & Filter is hiding some: V switches the filter off" : "Shown / all photos in the folder")
            // shortened while there is room for a few words; below that hidden (a lone "…" says nothing)
            ViewThatFits(in: .horizontal) {
                Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(minWidth: 90, alignment: .leading)
                Color.clear.frame(width: 0)
            }
            .layoutPriority(-1)
                .help(m.status)
            Spacer(minLength: 6)
            Button("Export As…") { m.exportCurrent() }.glassButton().disabled(m.current == nil || m.exporting).fixedSize().layoutPriority(2)
                .help("This photo with its look, to a place you choose (⌘E)")
            Button(m.exportAllTitle) { m.exportAll() }
                .fixedSize().layoutPriority(2)
                .glassButton(prominent: true)
                .help(m.exportOwnLook ? "Exports the \(m.exportScopeText) photos, each with its own look (rejected ones never). Export settings: ⚙︎"
                      : "Exports the \(m.exportScopeText) photos once per look ticked in the LUT panel (rejected ones never)")
                .disabled(m.exportTargets.isEmpty || m.batchPPs.isEmpty || m.exporting || (m.outputMode.needsFolder && m.customOut == nil))
            Button { m.sheet = .export } label: { Image(systemName: "gearshape") }.help("Export settings")
            Button { m.sheet = .help } label: { Image(systemName: "questionmark.circle") }.help("Keyboard shortcuts (F1)")
        }
        .padding(.horizontal, 10)
    }

    var ratingControls: some View {
        let p = m.photo(m.current)
        return HStack(spacing: 2) {
            StarStrip(rating: max(p?.rating ?? 0, 0)) { m.setRating($0) }
            Button { m.setRating(-1) } label: {
                hitTarget(Image(systemName: p?.isRejected == true ? "xmark.circle.fill" : "xmark.circle").foregroundStyle(.red), width: 18)
            }.buttonStyle(.plain).help("Reject (X)")
            ForEach(labelNames, id: \.self) { n in
                Button { m.setLabel(n) } label: {
                    hitTarget(Circle().fill(labelColor(n)).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.primary.opacity(p?.label == n ? 1 : 0.15), lineWidth: 2)), width: 12)
                }.buttonStyle(.plain).help(n == "Purple" ? "Label Purple; again to clear" : "Label \(n) (\(labelNames.firstIndex(of: n)! + 6)); again to clear")
            }
        }
        .disabled(m.current == nil)
    }

    func indicator(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(on ? Color.accentColor : Color.gray.opacity(0.25)).foregroundStyle(on ? Color.white : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(minHeight: 30).contentShape(Rectangle())     // the target, not the look
        }.buttonStyle(.plain)
    }

    // MARK: sheets

    var exportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export settings").font(.headline)
            Text("\(m.exportTargets.count) \(m.exportScopeText) photo(s) → 10-bit HEIC. Rejected photos are never exported.")
                .font(.caption).foregroundStyle(.secondary)

            GroupBox("Looks") {
                Picker("", selection: $m.exportOwnLook) {
                    Text("Each photo's own look (the one saved for it, else the current look)").tag(true)
                    Text("The looks ticked in the LUT panel (\(m.batchPPs.count)), each photo once per look").tag(false)
                }
                .pickerStyle(.radioGroup).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .help("Which look each exported photo gets")
            }

            GroupBox("Sidecar") {
                Toggle("Copy the .xmp next to each export", isOn: $m.copySidecar).frame(maxWidth: .infinity, alignment: .leading)
                    .help("Puts a copy of the photo's .xmp (rating, label, settings) beside each HEIC")
            }
            GroupBox("Quality") {
                HStack {
                    Slider(value: $m.quality, in: 0.5...1).help("HEIC quality: higher is larger and finer")
                    Text(String(format: "%.2f", m.quality)).monospacedDigit()
                }
            }
            GroupBox("Output") {
                VStack(alignment: .leading) {
                    Picker("", selection: $m.outputMode) {
                        ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .help("Where the exported files go")
                    Toggle("Put each look in its own folder (PP3/, Fujifilm-ASTIA/ …)", isOn: $m.groupByLook).font(.caption)
                        .help("A subfolder per look inside the output folder")
                    if m.outputMode.needsFolder {
                        Text(m.customOut?.path ?? "No folder chosen").font(.caption).lineLimit(2).truncationMode(.middle)
                    }
                    HStack {
                        Button("Choose…") { m.chooseOutput() }.help("Choose the output folder")
                        Menu("Recent") {
                            ForEach(m.recentOutputs, id: \.self) { u in
                                Button(u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent) { m.useOutput(u) }
                            }
                        }
                        .disabled(m.recentOutputs.isEmpty).help("Output folders used before")
                        if m.customOut != nil { Button("Reset") { m.customOut = nil }.help("Forget the chosen folder") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { m.sheet = nil }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 440)
    }

    var helpSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Shortcuts.groups, id: \.title) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(g.title).font(.subheadline.bold())
                            ForEach(g.items, id: \.keys) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.keys).font(.system(size: 12, design: .monospaced)).frame(width: 130, alignment: .leading)
                                    Text(item.text).font(.system(size: 12))
                                }
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { m.sheet = nil }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 600, height: 520)
    }
}

/// The five stars in the status bar. A click sets that many; a drag along them sets the rating where it is let go,
/// and dragging off the left of the first star clears it (no other way to get back to no stars without a key).
struct StarStrip: View {
    let rating: Int
    let set: (Int) -> Void
    final class Box: ObservableObject {
        @Published var preview: Int?            // the rating under the pointer while dragging
        var dragEnded = Date.distantPast        // a drag let go over a star is not also a click on it
    }
    @StateObject private var box = Box()
    static let cell: CGFloat = 14, gap: CGFloat = 2

    var body: some View {
        let shown = box.preview ?? rating
        HStack(spacing: Self.gap) {
            ForEach(1...5, id: \.self) { i in
                Button { if Date().timeIntervalSince(box.dragEnded) > 0.3 { set(i) } } label: {
                    Image(systemName: i <= shown ? "star.fill" : "star").font(.system(size: 11)).foregroundStyle(.orange)
                        .opacity(box.preview != nil && i > shown ? 0.45 : 1)
                        .frame(minWidth: Self.cell, minHeight: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(i) star\(i == 1 ? "" : "s") (\(i)). Drag along the stars to set, off the left end to clear (0)")
            }
        }
        // a drag, not a click: the buttons keep their clicks
        .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { g in
            box.preview = Self.stars(at: g.location.x)
        }.onEnded { g in
            let r = Self.stars(at: g.location.x)
            box.preview = nil
            box.dragEnded = Date()
            if r != rating { set(r) }
        })
    }

    /// Stars for a point along the strip: left of the first star's middle is none, past the last is five.
    static func stars(at x: CGFloat) -> Int {
        let stride = cell + gap
        guard x >= cell / 2 else { return 0 }
        return min(5, max(1, Int((x / stride).rounded(.up))))
    }
}
