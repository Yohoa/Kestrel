import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Filmstrip, status bar and sheets.

extension ContentView {
    // MARK: filmstrip (the mouse wheel scrolls it sideways)

    var filmstrip: some View { FilmstripView(m: m, thumbs: thumbs, menu: { AnyView(photoMenu($0)) }) }

    // MARK: status bar

    /// Also redrawn on its own when the status line or the export progress changes (they don't redraw the window).
    var statusBar: some View { Observing(m.statusState) { _ in statusBarContent } }

    /// Status-bar buttons are small to look at but get a target the size of a fingertip (Sidecar, trackpad).
    func hitTarget<V: View>(_ v: V, width: CGFloat = 22) -> some View {
        v.frame(minWidth: width, minHeight: 34).contentShape(Rectangle())
    }

    var statusBarContent: some View {
        HStack(spacing: 9) {
            Button { m.step(-1) } label: { hitTarget(Image(systemName: "chevron.left")) }
                .buttonStyle(.plain).disabled((m.currentIndex ?? 0) == 0)
            Text(m.currentIndex.map { "\($0 + 1)/\(m.files.count)" } ?? "–/\(m.files.count)")
                .font(.system(size: 12).monospacedDigit()).lineLimit(1).fixedSize().frame(minWidth: 50)
            Button { m.step(1) } label: { hitTarget(Image(systemName: "chevron.right")) }
                .buttonStyle(.plain).disabled(m.currentIndex.map { $0 >= m.files.count - 1 } ?? true)
            Text(m.current?.lastPathComponent ?? "").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Text(m.imageSize).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Divider()
            Button { m.nudgeExposure(NSEvent.modifierFlags.contains(.shift) ? -1 : -1.0 / 3) } label: { hitTarget(Image(systemName: "minus.square")) }.buttonStyle(.plain)
            Text(String(format: "%+.2f EV", m.exposure)).font(.system(size: 12).monospacedDigit()).lineLimit(1).fixedSize()
            Button { m.nudgeExposure(NSEvent.modifierFlags.contains(.shift) ? 1 : 1.0 / 3) } label: { hitTarget(Image(systemName: "plus.square")) }.buttonStyle(.plain)
            Menu("\(m.wbIsCustom ? "WB" : "As shot") \(Int(m.temperature))K/\(Int(m.tint))") {
                ForEach(WBPreset.all) { p in Button(p.name) { m.applyWBPreset(p) } }
                Divider()
                Button("Pick neutral…") { m.pickingWB = true }
            }
            .fixedSize()
            Divider()
            ratingControls
            Divider()
            indicator("O", on: m.showOver) { m.toggleOver() }
            indicator("U", on: m.showUnder) { m.toggleUnder() }
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
            if m.currentIsSelected {
                Text("Sel").font(.caption.bold()).foregroundStyle(.red).help("The photo on screen is part of the selection")
            }
            if m.hasGroup {
                Text("\(m.selection.count) selected").font(.caption).foregroundStyle(Color.accentColor)
                    .help("Ratings, labels, ⌘V, Apply to…, Copy WB to… and Export act on these. Esc clears.")
            }
            Divider()
            if m.exporting {
                ProgressView(value: m.progress).frame(width: 80)
                Button("Cancel") { m.cancelExport() }.controlSize(.small)
            }
            Button { withAnimation(LayoutStore.spring) { m.toggle(.filmstrip) } } label: {
                Image(systemName: "film").foregroundStyle(m.shown(.filmstrip) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).disabled(m.viewMode == .grid)
            .help(m.shown(.filmstrip) ? "Fold the filmstrip (F6)" : "Show the filmstrip (F6)")
            Button { m.toggleGrid() } label: { Image(systemName: m.viewMode == .grid ? "photo" : "square.grid.2x2") }
                .buttonStyle(.plain).help(m.viewMode == .grid ? "Single photo (G)" : "Grid view (G)")
            if m.viewMode == .grid { Slider(value: $m.gridCell, in: 120...360).frame(width: 90) }
            Text("\(m.shownPhotos.count)/\(m.library.count)\(m.filter.isActive ? " filtered" : "")\(m.rejectedHidden > 0 ? " · \(m.rejectedHidden) rejected hidden" : "")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(m.filter.isActive ? Color.accentColor : .secondary)
            Text(m.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            Spacer(minLength: 6)
            Button("Export As…") { m.exportCurrent() }.glassButton().disabled(m.current == nil || m.exporting)
                .help("This photo with its look, to a place you choose (⌘E)")
            Button(m.exportAllTitle) { m.exportAll() }
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
            ForEach(1...5, id: \.self) { i in
                Button { m.setRating(i) } label: {
                    hitTarget(Image(systemName: i <= (p?.rating ?? 0) ? "star.fill" : "star").font(.system(size: 11)).foregroundStyle(.orange), width: 14)
                }.buttonStyle(.plain)
            }
            Button { m.setRating(-1) } label: {
                hitTarget(Image(systemName: p?.isRejected == true ? "xmark.circle.fill" : "xmark.circle").foregroundStyle(.red), width: 18)
            }.buttonStyle(.plain).help("Reject (X)")
            ForEach(labelNames, id: \.self) { n in
                Button { m.setLabel(n) } label: {
                    hitTarget(Circle().fill(labelColor(n)).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.primary.opacity(p?.label == n ? 1 : 0.15), lineWidth: 2)), width: 12)
                }.buttonStyle(.plain)
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
                .frame(minHeight: 34).contentShape(Rectangle())     // the target, not the look
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
            }

            GroupBox("Sidecar") {
                Toggle("Copy the .xmp next to each export", isOn: $m.copySidecar).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Quality") {
                HStack {
                    Slider(value: $m.quality, in: 0.5...1)
                    Text(String(format: "%.2f", m.quality)).monospacedDigit()
                }
            }
            GroupBox("Output") {
                VStack(alignment: .leading) {
                    Picker("", selection: $m.outputMode) {
                        ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    Toggle("Put each look in its own folder (PP3/, Fujifilm-ASTIA/ …)", isOn: $m.groupByLook).font(.caption)
                    if m.outputMode.needsFolder {
                        Text(m.customOut?.path ?? "No folder chosen").font(.caption).lineLimit(2).truncationMode(.middle)
                    }
                    HStack {
                        Button("Choose…") { m.chooseOutput() }
                        Menu("Recent") {
                            ForEach(m.recentOutputs, id: \.self) { u in
                                Button(u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent) { m.useOutput(u) }
                            }
                        }
                        .disabled(m.recentOutputs.isEmpty)
                        if m.customOut != nil { Button("Reset") { m.customOut = nil } }
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
