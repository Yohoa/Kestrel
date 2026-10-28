import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// The picture (single view) and the grid.

extension ContentView {
    // MARK: centre

    @ViewBuilder var centerArea: some View {
        if m.current == nil && m.library.isEmpty {
            ZStack { Color.black.opacity(m.stageOpacity); startScreen }
        } else if m.viewMode == .grid { gridView } else { singleView }
    }

    /// Shown only while no photo is open (first launch, or an empty folder): Open and History in the middle.
    /// Otherwise they live in the menu bar (File → Open…, File → Recent Folders).
    var startScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 46)).foregroundStyle(.secondary)
            if let hint = m.emptyHint {
                Text(hint).foregroundStyle(.secondary)
            } else {
                Text("Open a folder of ARW / RAF / CR2 / DNG files, pick one in Folders, or drop it here").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { m.open() } label: { Label("Open…", systemImage: "folder").padding(.horizontal, 8) }
                    .glassButton(prominent: true).controlSize(.large).help("Open a folder or RAW files (⌘O)")
                Menu {
                    ForEach(m.recentInputs, id: \.self) { u in
                        Button(u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent) { m.load([u]) }
                    }
                    Divider()
                    Button("Clear History") { m.clearHistory() }
                } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .menuStyle(.button).controlSize(.large).fixedSize()
                    .disabled(m.recentInputs.isEmpty).help("Folders opened before")
            }
            Toggle("Include subfolders", isOn: $m.includeSubfolders).toggleStyle(.checkbox).font(.caption)
                .help("Also show the photos in the folders inside the one you open")
        }
    }

    var singleView: some View { previewArea }

    var previewArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(m.stageOpacity)
                previewContent
                if m.pickingWB {
                    VStack {
                        Text("Click a neutral grey or white area (Esc cancels)")
                            .padding(.horizontal, 12).padding(.vertical, 6).glassCapsule()
                        Spacer()
                    }.padding(10)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)    // a zoomed picture is larger than the view:
            .clipped()                                                // keep it centred, not pinned top-left
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { if m.zoomed { m.dragPan($0.translation) } }
                .onEnded { v in
                    // not zoomed: a quick sideways drag turns the photo (a Pencil or finger on a Sidecar iPad, a mouse)
                    if !m.zoomed { m.dragSwipe(v.translation, predicted: v.predictedEndTranslation) }
                    m.endPan()
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { v in
                if m.pickingWB { m.pickWhite(atFit: v.location) }
            })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                if m.pickingWB { return }
                if m.zoomed { m.toggleZoom() } else { m.toggleZoom(atFit: v.location) }
            })
            .overlay(ScrollCatcher(mode: .picture,
                                   onDelta: { dx, dy, momentum in m.handleScroll(dx: dx, dy: dy, momentum: momentum) },
                                   onPinch: { mag, p, ended in m.pinch(Double(mag), at: p, ended: ended) },
                                   onSmartMagnify: { p in if m.zoomed { m.toggleZoom() } else { m.toggleZoom(atFit: p) } },
                                   onScrollBegan: { m.scrollGestureBegan() },
                                   onSwipe: { m.swipePhoto($0) }))
            .contextMenu { if m.current != nil { pictureMenu } }
            .overlay(alignment: .bottom) { NoticeView(center: m.notices, place: .picture).padding(.bottom, 8) }
            .onChange(of: geo.size) { _, s in m.viewSize = s }
            .onAppear { m.viewSize = geo.size }
        }
    }

    /// Right-click on the photo. Marking first (what culling is about), then the automatic fixes, getting the picture
    /// out, undo, and last the file itself. Ratings, labels and Move act on what keys act on (the group in the grid).
    @ViewBuilder var pictureMenu: some View {
        let ts = m.metadataTargets()
        Menu {
            ForEach((1...5).reversed(), id: \.self) { i in Button(String(repeating: "★", count: i)) { m.setRating(i, on: ts) } }
            Divider()
            Button("No rating") { m.setRating(0, on: ts) }
            Button("Reject (X)") { m.setRating(-1, on: ts) }
        } label: { Label("Rating", systemImage: "star") }
        Menu {
            ForEach(labelNames, id: \.self) { n in Button(n) { m.setLabel(n, on: ts) } }
            Divider()
            Button("No label") { m.setLabel(nil, on: ts) }
        } label: { Label("Label", systemImage: "tag") }
        Divider()
        Button { m.autoExposure(scope: m.current.map { [$0] } ?? []) } label: { Label("Auto Exposure", systemImage: "plusminus.circle") }
        Button { m.applyAutoWB() } label: { Label("Auto White Balance", systemImage: "thermometer.sun") }
        Divider()
        Button { m.quickExport() } label: { Label("Quick Export", systemImage: "square.and.arrow.up") }.disabled(m.exporting)
            .help("No dialog: into the folder the Export settings name (a HEIC folder next to the RAW by default)")
        Button("Export As…") { m.exportCurrent() }.disabled(m.exporting).help("Asks where to save this photo as a 10-bit HEIC (⌘E)")
        Button { m.copyImageToClipboard() } label: { Label("Copy Edited Photo", systemImage: "doc.on.doc") }
            .help("The photo as developed here (look, exposure, white balance), full size, for pasting elsewhere")
        Divider()
        Button { m.undo.undo() } label: { Label(m.undo.undoTitle.map { "Undo \($0)" } ?? "Undo", systemImage: "arrow.uturn.backward") }
            .disabled(m.undo.undoTitle == nil).help("⌘Z")
        Button { m.undo.redo() } label: { Label(m.undo.redoTitle.map { "Redo \($0)" } ?? "Redo", systemImage: "arrow.uturn.forward") }
            .disabled(m.undo.redoTitle == nil).help("⇧⌘Z")
        Divider()
        Button { m.moveToRejected() } label: {
            Label(ts.count > 1 ? "Move \(ts.count) Photos to \(Model.rejectedFolderName)" : "Move to \(Model.rejectedFolderName)", systemImage: "archivebox")
        }
        .help("Moves the photo(s) and their .xmp into a _Rejected folder next to them (⇧⌘⌫); ⌘Z moves them back")
        Button("Reveal in Finder") { if let c = m.current { m.revealInFinder(c) } }
    }

    @ViewBuilder var previewContent: some View {
        if let err = m.previewError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.yellow)
                Text(err).foregroundStyle(.secondary)
                Text("The file may be damaged or unsupported. ←/→ still moves on.").font(.caption).foregroundStyle(.secondary)
            }
        } else if m.zoomed, let z = m.zoomImage ?? m.preview {
            // until the sharp render arrives, the fitted preview is enlarged in its place
            ZoomedPicture(zoom: m.zoomState, image: z, overlay: m.overlay, fullSize: m.fullSizePt,
                          sharp: m.zoomImage != nil, busy: m.zoomImage == nil)
        } else if let img = m.preview {
            ZStack {
                Image(nsImage: img).resizable().scaledToFit()
                if let ov = m.overlay { Image(nsImage: ov).resizable().interpolation(.none).scaledToFit().allowsHitTesting(false) }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {                // in the corner, as when zoomed, not over the picture
                if m.zoomed || m.previewIsPlaceholder { loadingBadge }
            }
        } else if m.current != nil {
            Color.clear.overlay(alignment: .topTrailing) { loadingBadge }
        } else if let hint = m.emptyHint {
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(hint).foregroundStyle(.secondary)
                if !m.includeSubfolders {
                    Button("Include subfolders") { m.includeSubfolders = true; m.includeSubfoldersChanged() }
                        .help("Show the photos in the folders inside this one too")
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Open a folder of ARW / RAF / CR2 / DNG files, pick one in Folders, or drop it here").foregroundStyle(.secondary)
            }
        }
    }

    var developPanel: some View {
        PanelBox("Develop", panel: .develop, onClose: { m.toggle(.develop) }) {
            VStack(spacing: 6) {
                HStack {
                    Text(m.look.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .help("The look (LUT) on this photo; pick another in the LUT panel, or [ ] to step")
                    if m.lutInput(m.ppID) != nil { LUTInputLine(m: m, lookID: m.ppID) }
                    Spacer()
                }
                adjustRow("Exposure", value: $m.exposure, range: -4...7, step: 0.1, typedStep: 0.01, format: "%+.2f", unit: " EV",
                          reset: { m.editCurrent { $0.ev = 0 }; m.developChanged() })
                adjustRow("Temp", value: $m.temperature, range: 2500...10000, step: 50, typedStep: 10, format: "%.0f", unit: " K",
                          reset: { m.resetWB(); m.developChanged() })
                adjustRow("Tint", value: $m.tint, range: -50...50, step: 1, format: "%+.0f",
                          reset: { m.resetWB(); m.developChanged() })
                adjustRow("Contrast", value: $m.contrast, range: -5...5, step: 0.1, format: "%+.1f",
                          reset: { m.editCurrent { $0.contrast = 0 }; m.developChanged() })
                    .help("FastRawViewer contrast grade −5…+5 in 0.1 steps; K / ⇧K move ½ grade")
                HStack {
                    Toggle("Highlight recovery", isOn: $m.highlightRecovery).font(.caption)
                        .onChange(of: m.highlightRecovery) { _, _ in m.developChanged() }
                        .help("Brings back detail in bright areas that would otherwise clip to white")
                    Spacer()
                    Button("Reset") { m.resetAdjustments(); m.developChanged() }.controlSize(.small)
                        .help("Exposure, contrast, highlight recovery and white balance back to their defaults (the look stays)")
                }
                ViewThatFits(in: .horizontal) {                  // narrow column: Copy / Paste move into Apply to…
                    HStack(spacing: 6) { developMenus(compact: false); Spacer(); copyPaste }
                    HStack(spacing: 6) { developMenus(compact: true); Spacer() }
                }
            }
            .padding(8)
        }
    }

    /// Slider without tick marks (the step is applied by rounding) and a small knob, so it can take the whole row;
    /// the value next to it can be clicked and typed into.
    /// `typedStep`: a typed value may be finer than the slider's step (Auto EV gives e.g. −1.27).
    func adjustRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, typedStep: Double? = nil,
                   format: String, unit: String = "", reset: (() -> Void)? = nil) -> some View {
        let stepped = Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
        return HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 52, alignment: .leading).help(Self.adjustTip(title))
            Slider(value: stepped, in: range) { editing in
                if editing { m.beginSliderDrag() } else { m.endSliderDrag(); m.developChanged() }   // live while dragging
            }
            .controlSize(.small).help(Self.adjustTip(title))
            ValueField(value: value, range: range, step: typedStep ?? step, dragStep: step, format: format, unit: unit,
                       onDragBegin: { m.beginSliderDrag() }, onDragEnd: { m.endSliderDrag(); m.developChanged() },
                       onReset: reset) { m.developChanged() }
        }
    }

    @ViewBuilder func developMenus(compact: Bool) -> some View {
        Menu("Auto EV") {
            Button("This photo") { m.autoExposure(scope: m.current.map { [$0] } ?? []) }
            Button("Selection (\(m.selection.count))") { m.autoExposure(scope: m.actionTargets()) }.disabled(!m.hasGroup)
            Button("Every shown photo") { m.autoExposure(scope: m.files) }
            Divider()
            Menu("Metering: \(m.meteringMode.title)") {
                ForEach(MeteringMode.allCases) { mode in
                    Button { m.meteringMode = mode } label: { Text((m.meteringMode == mode ? "✓ " : "    ") + mode.title) }
                }
            }
        }
        .fixedSize().disabled(m.current == nil)
        .help("Meter the exposure automatically (⇧A), for this photo, the selection or every shown photo")
        Menu(m.hasGroup ? "Apply to… (\(m.selection.count))" : "Apply to…") {
            Button("Selection (\(m.selection.count))") { m.applyCurrentSettings(to: m.actionTargets()) }.disabled(!m.hasGroup)
            Button("Every shown photo (\(m.files.count))") { m.applyCurrentSettings(to: m.files) }
            if compact {
                Divider()
                ForEach(ShortcutAction.allCases) { a in Button(a.menuTitle) { m.perform(a) } }
                Button("Paste settings (⌘V)") { m.pasteSettings() }
            }
        }
        .fixedSize().disabled(m.current == nil)
        .help("Give the selection or every shown photo this photo's settings (exposure, contrast, white balance, look)")
    }

    static func adjustTip(_ title: String) -> String {
        switch title {
        case "Exposure": "Brightness in EV stops. A sets 0 (A again restores it), ⇧A meters automatically, ⌥+ / ⌥− step"
        case "Temp": "White balance colour temperature in Kelvin: lower is bluer, higher warmer"
        case "Tint": "White balance tint: minus is greener, plus more magenta"
        case "Contrast": "FastRawViewer contrast grade −5…+5 in 0.1 steps; K / ⇧K move ½ grade"
        default: title
        }
    }

    @ViewBuilder var copyPaste: some View {
        Menu("Copy") {
            ForEach(ShortcutAction.allCases) { a in Button(a.menuTitle) { m.perform(a) } }
        } primaryAction: { m.copySettings() }                         // a click copies everything
            .controlSize(.small).fixedSize().help("Click: copy all settings. ▾: Develop, White Balance or LUT only")
        Button("Paste") { m.pasteSettings() }.controlSize(.small).fixedSize().help("Paste the copied settings (⌘V)")
    }

    /// The spinner shown while the picture for a newly selected photo is on its way.
    var loadingBadge: some View { ProgressView().controlSize(.small).padding(10).glassCapsule().padding(8).help("Rendering the photo…") }

    // MARK: grid view

    var gridView: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    Observing(thumbs) { thumbs in
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(m.gridCell + 6), spacing: 8), count: max(1, m.gridColumns)), spacing: 8) {
                        ForEach(m.shownPhotos) { p in
                            GridCell(photo: p, isCurrent: p.url == m.current, isSelected: m.selection.contains(p.url),
                                     size: m.gridCell, image: thumbs.images[p.url], hovered: thumbs.hovered == p.url, store: thumbs,
                                     markBox: m.advancedSelection, onMark: { m.toggleMark(p.url) })
                                .equatable()
                                .id(p.url)
                                // the click acts at once; a double-tap handler in front of it made every click wait
                                // the double-click interval (~0.3 s) to see whether a second one came
                                .onTapGesture { m.click(p.url, command: NSEvent.modifierFlags.contains(.command), shift: NSEvent.modifierFlags.contains(.shift)) }
                                .simultaneousGesture(TapGesture(count: 2).onEnded { m.open(p.url) })
                                .contextMenu { photoMenu(p.url) }
                        }
                    }
                    .padding(8)
                    }                                   // Observing(thumbs): the cells get their thumbnails from here
                }
                // Just far enough to show the whole photo (anchor nil), for keys and clicks alike: a photo already in
                // view stays put (centring it moved it from under the pointer, so a double-click hit another
                // photo); one cut off at the top or bottom edge is brought fully in.
                .onChange(of: m.current) { _, new in if let new { proxy.scrollTo(new) } }
                // back from the single view (G): open on the photo just viewed, not at the top
                .onAppear {
                    guard let c = m.current else { return }
                    DispatchQueue.main.async { proxy.scrollTo(c, anchor: .center) }   // after the grid's first layout
                }
            }
            .onAppear { updateColumns(geo.size.width) }
            .onChange(of: geo.size.width) { _, w in updateColumns(w) }
            .onChange(of: m.gridCell) { _, _ in updateColumns(geo.size.width) }
        }
        .background(Color.black.opacity(m.stageOpacity))
    }

    func updateColumns(_ width: CGFloat) {
        m.gridColumns = max(1, Int((width - 16) / (m.gridCell + 14)))
    }

}

/// The LUT's input space in Develop, read-only: it comes from the LUT's file name ("…_VLog", "…SLog3…"). Setting
/// it by hand is hidden for now (it wrote a file next to the LUTs, which for the built-in ones is inside the app).
struct LUTInputLine: View {
    @ObservedObject var m: Model
    let lookID: Int

    var body: some View {
        if let info = m.lutInput(lookID) {
            let how = info.source == .fileName ? "from file name" : info.source == .manual ? "set earlier" : "assumed"
            Text("Input: \(info.space.name) (\(how))")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .help(info.source == .assumed
                      ? "The file name doesn't say which camera log this LUT expects, so S-Log3 / S-Gamut3.Cine is assumed. Names with VLog, SLog3, FLog2 … are read automatically."
                      : "The camera log this LUT expects, read from its file name.")
        }
    }
}

