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
                Text("Open a folder of ARW / RAF / DNG files, pick one in Folders, or drop it here").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { m.open() } label: { Label("Open…", systemImage: "folder").padding(.horizontal, 8) }
                    .glassButton(prominent: true).controlSize(.large)
                Menu {
                    ForEach(m.recentInputs, id: \.self) { u in
                        Button(u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent) { m.load([u]) }
                    }
                    Divider()
                    Button("Clear History") { m.clearHistory() }
                } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .menuStyle(.button).controlSize(.large).fixedSize()
                    .disabled(m.recentInputs.isEmpty)
            }
            Toggle("Include subfolders", isOn: $m.includeSubfolders).toggleStyle(.checkbox).font(.caption)
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
        Button { m.quickExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(m.exporting)
        Button("Export As…") { m.exportCurrent() }.disabled(m.exporting)
        Button { m.copyImageToClipboard() } label: { Label("Copy Edited Photo", systemImage: "doc.on.doc") }
            .help("The photo as developed here (look, exposure, white balance), full size, for pasting elsewhere")
        Divider()
        Button { m.undo.undo() } label: { Label(m.undo.undoTitle.map { "Undo \($0)" } ?? "Undo", systemImage: "arrow.uturn.backward") }
            .disabled(m.undo.undoTitle == nil)
        Button { m.undo.redo() } label: { Label(m.undo.redoTitle.map { "Redo \($0)" } ?? "Redo", systemImage: "arrow.uturn.forward") }
            .disabled(m.undo.redoTitle == nil)
        Divider()
        Button { m.moveToRejected() } label: {
            Label(ts.count > 1 ? "Move \(ts.count) Photos to \(Model.rejectedFolderName)" : "Move to \(Model.rejectedFolderName)", systemImage: "archivebox")
        }
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
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Open a folder of ARW / RAF / DNG files, pick one in Folders, or drop it here").foregroundStyle(.secondary)
            }
        }
    }

    var developPanel: some View {
        PanelBox("Develop", panel: .develop, onClose: { m.toggle(.develop) }) {
            VStack(spacing: 6) {
                HStack {
                    Text(m.look.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if m.lutInput(m.ppID) != nil { LUTInputLine(m: m, lookID: m.ppID) }
                    Spacer()
                }
                adjustRow("Exposure", value: $m.exposure, range: -4...7, step: 0.1, typedStep: 0.01, format: "%+.2f", unit: " EV")
                adjustRow("Temp", value: $m.temperature, range: 2500...10000, step: 50, typedStep: 10, format: "%.0f", unit: " K")
                adjustRow("Tint", value: $m.tint, range: -50...50, step: 1, format: "%+.0f")
                adjustRow("Contrast", value: $m.contrast, range: -5...5, step: 0.1, format: "%+.1f")
                    .help("FastRawViewer contrast grade −5…+5 in 0.1 steps; K / ⇧K move ½ grade")
                HStack {
                    Toggle("Highlight recovery", isOn: $m.highlightRecovery).font(.caption)
                        .onChange(of: m.highlightRecovery) { _, _ in m.developChanged() }
                    Spacer()
                    Button("Reset") { m.resetAdjustments(); m.developChanged() }.controlSize(.small)
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
                   format: String, unit: String = "") -> some View {
        let stepped = Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
        return HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: stepped, in: range) { editing in
                if editing { m.beginSliderDrag() } else { m.endSliderDrag(); m.developChanged() }   // live while dragging
            }
            .controlSize(.small)
            ValueField(value: value, range: range, step: typedStep ?? step, format: format, unit: unit) { m.developChanged() }
        }
    }

    @ViewBuilder func developMenus(compact: Bool) -> some View {
        Menu("Auto EV") {
            Button("This photo") { m.autoExposure(scope: m.current.map { [$0] } ?? []) }
            Button("Selection (\(m.selection.count))") { m.autoExposure(scope: m.actionTargets()) }.disabled(!m.hasGroup)
            Button("Every shown photo") { m.autoExposure(scope: m.files) }
            Divider()
            Menu("Metering: \(m.meteringMode.rawValue)") {
                ForEach(MeteringMode.allCases) { mode in
                    Button { m.meteringMode = mode } label: { Text((m.meteringMode == mode ? "✓ " : "    ") + mode.title) }
                }
            }
        }
        .fixedSize().disabled(m.current == nil)
        Menu(m.hasGroup ? "Apply to… (\(m.selection.count))" : "Apply to…") {
            Button("Selection (\(m.selection.count))") { m.applyCurrentSettings(to: m.actionTargets()) }.disabled(!m.hasGroup)
            Button("Every shown photo (\(m.files.count))") { m.applyCurrentSettings(to: m.files) }
            if compact {
                Divider()
                Button("Copy settings (⌘C)") { m.copySettings() }
                Button("Paste settings (⌘V)") { m.pasteSettings() }
            }
        }
        .fixedSize().disabled(m.current == nil)
    }

    @ViewBuilder var copyPaste: some View {
        Button("Copy") { m.copySettings() }.controlSize(.small).fixedSize()
        Button("Paste") { m.pasteSettings() }.controlSize(.small).fixedSize()
    }

    /// The spinner shown while the picture for a newly selected photo is on its way.
    var loadingBadge: some View { ProgressView().controlSize(.small).padding(10).glassCapsule().padding(8) }

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
                                .onTapGesture(count: 2) { m.open(p.url) }
                                .onTapGesture { m.click(p.url, command: NSEvent.modifierFlags.contains(.command), shift: NSEvent.modifierFlags.contains(.shift)) }
                                .contextMenu { photoMenu(p.url) }
                        }
                    }
                    .padding(8)
                    }                                   // Observing(thumbs): the cells get their thumbnails from here
                }
                .onChange(of: m.current) { _, new in if let new { proxy.scrollTo(new, anchor: .center) } }
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

/// The LUT's input space in Develop. A name that says it ("…_VLog") makes it a read-only line, so it can't be
/// changed by accident; ⌥-click it to set one by hand anyway. A hand-made setting shows "(manual)" and can go back
/// to the file name; a name that says nothing keeps the menu, with a hint.
struct LUTInputLine: View {
    @ObservedObject var m: Model
    let lookID: Int
    @StateObject private var box = Box()
    final class Box: ObservableObject { @Published var picking = false }

    var body: some View {
        if let info = m.lutInput(lookID) {
            switch info.source {
            case .fileName:
                Text("Input: \(info.space.name) (from file name)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { if NSEvent.modifierFlags.contains(.option) { box.picking = true } }
                    .help("Read from the LUT's file name. ⌥-click to set it by hand (also in the LUT thumbnail's right-click menu).")
                    .popover(isPresented: $box.picking, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input this LUT expects").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                            ForEach(Scenes.lutInputs, id: \.name) { opt in
                                Button { m.setLUTInput(opt, for: lookID); box.picking = false } label: {
                                    Label(opt.name, systemImage: opt.name == info.space.name ? "checkmark" : "")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
            case .manual:
                Menu("Input: \(info.space.name) (manual)") { LUTInputChoices(m: m, lookID: lookID) }
                    .fixedSize().controlSize(.small)
                    .help("Set by hand, kept in kestrel-lut-inputs.json in the LUT folder")
            case .assumed:
                VStack(alignment: .leading, spacing: 1) {
                    Menu("Input: \(info.space.name)") { LUTInputChoices(m: m, lookID: lookID) }
                        .fixedSize().controlSize(.small)
                    Text("Choose the input this LUT expects").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The input spaces to pick from, plus "Use file name" when a hand-made setting can be dropped.
struct LUTInputChoices: View {
    @ObservedObject var m: Model
    let lookID: Int

    var body: some View {
        if let info = m.lutInput(lookID) {
            ForEach(Scenes.lutInputs, id: \.name) { opt in
                Button { m.setLUTInput(opt, for: lookID) } label: {
                    if opt.name == info.space.name { Label(opt.name, systemImage: "checkmark") } else { Text(opt.name) }
                }
            }
            if info.source == .manual {
                Divider()
                Button(info.guess.map { "Use File Name (\($0.name))" } ?? "Use File Name (none: assume S-Log3 / S-Gamut3.Cine)") {
                    m.useFileNameInput(for: lookID)
                }
            }
        }
    }
}

