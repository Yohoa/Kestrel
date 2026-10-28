import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// FastRawViewer-style layout: Folders / Favorite folders / EXIF / XMP on the left, the picture (or a grid) in the
// middle, Histogram / Exposure stats / White balance / LUT on the right, a filter bar, the photo filmstrip and a
// status bar along the bottom.

// MARK: - Main view

struct ContentView: View {
    @ObservedObject var m: Model
    var thumbs: ThumbStore { m.filmThumbs }          // shared with the model: the first preview placeholder

    var body: some View {
        VStack(spacing: 4) {
            Observing(m.layoutStore) { layout in HStack(spacing: 0) {
                // Side columns: drag the handle to resize, click it (or ⌥⌘[ / ⌥⌘]) to fold.
                // a side with nothing to show (all hidden, Tab) keeps the same drop zone, folded or not, so both
                // edges of the picture get the same margin; it is slimmer in full screen, like the folded strips
                if layout.leftCollapsed { if m.leftVisible { FoldedSidebar(store: layout, left: true) } else { column("left", width: 0) } }
                else {
                    column("left", width: layout.leftWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    if m.leftVisible { SidebarSplitter(store: layout, left: true) }
                }
                centerArea.clipShape(RoundedRectangle(cornerRadius: 14)).padding(3)
                if layout.rightCollapsed { if m.rightVisible { FoldedSidebar(store: layout, left: false) } else { column("right", width: 0) } }
                else {
                    if m.rightVisible { SidebarSplitter(store: layout, left: false) }
                    column("right", width: layout.rightWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Tab mode: an invisible strip at each edge peeks the panels Tab hid
            .overlay(alignment: .leading) { if !m.panelsHiddenByTab("left").isEmpty { edgeHover(layout, left: true) } }
            .overlay(alignment: .trailing) { if !m.panelsHiddenByTab("right").isEmpty { edgeHover(layout, left: false) } }
            .overlay(alignment: .leading) { if layout.peekLeft { peekIfAny("left", layout, left: true) } }
            .overlay(alignment: .trailing) { if layout.peekRight { peekIfAny("right", layout, left: false) } }
            }
            if m.shown(.filmstrip) && m.viewMode == .single {
                filmstrip.frame(height: 128).clipShape(RoundedRectangle(cornerRadius: 14)).softCard(14).padding(.horizontal, 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            statusBar.frame(height: 40).softCard(12).padding(.horizontal, 3)
        }
        .padding(6)                             // same gap on the sides as at the bottom
        .background(Color(nsColor: .windowBackgroundColor).opacity(m.windowTint))        // 0 = fully transparent window
        .background(WindowConfigurator { w in
            let first = m.mainWindow !== w
            m.mainWindow = w
            if first {
                NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { _ in
                    MainActor.assumeIsolated { m.layoutStore.fitToWindow() }      // narrow window: shrink, then fold columns
                }
            }
            DispatchQueue.main.async { m.layoutStore.fitToWindow() }
            // Small enough for an iPad as a Sidecar display or a split screen: the side columns shrink, then fold.
            w.minSize = NSSize(width: 760, height: 560)
            if w.frame.width < 760 || w.frame.height < 560 {            // a restored frame that is far too small
                let screen = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                let size = NSSize(width: min(1500, screen.width), height: min(940, screen.height))
                w.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
        })
        .environmentObject(m)
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle(m.current?.lastPathComponent ?? "Kestrel")     // still used by the Window menu
        .toolbar(removing: .title)                                         // …but not drawn under the traffic lights
        .toolbarBackground(.hidden, for: .windowToolbar)                   // the title bar shows the window's glass
        .sheet(item: $m.sheet) { kind in
            switch kind {
            case .export: exportSheet
            case .help: helpSheet
            case .welcome: WelcomeView(m: m)
            case .tips: TipsView(m: m)
            case .update: UpdateView(updater: m.updater) { m.sheet = nil }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in dropFiles(providers) }
    }

    // MARK: columns built from the (rearrangeable) layout

    enum PanelSize { case fixed(CGFloat), intrinsic, flexible }

    func size(of p: Panel) -> PanelSize {
        switch p {
        case .folders, .looks: return .flexible
        case .favorites: return .fixed(104)
        case .filter: return .fixed(CGFloat(m.layoutStore.contentHeights["filter"].map { $0 + 34 } ?? 320))   // + title, padding
        case .exif: return .fixed(174)                 // the seven lines without scrolling
        case .xmp: return .fixed(280)
        case .histogram: return .fixed(118)
        case .stats: return .fixed(96)
        case .develop: return .intrinsic
        case .whiteBalance: return .intrinsic
        case .filmstrip: return .fixed(128)
        }
    }

    @ViewBuilder func panelView(_ p: Panel) -> some View {
        switch p {
        case .folders: foldersPanel
        case .favorites: favoritesPanel
        case .filter: filterPanel
        case .exif: exifPanel
        case .xmp: xmpPanel
        case .histogram: PanelBox("Histogram", panel: .histogram, onClose: { m.toggle(.histogram) }) { histogramView }
        case .stats: PanelBox("Exposure Stats", panel: .stats, onClose: { m.toggle(.stats) }) { statsView }
        case .develop: developPanel
        case .whiteBalance: whiteBalancePanel
        case .looks: lutPanel
        case .filmstrip: EmptyView()
        }
    }

    /// The height set by dragging a gap, if it applies. A panel sized by its controls (Develop, White Balance) can be
    /// made taller that way but never shorter than its controls; anything else gives height back when the column is
    /// short and its contents scroll inside the box. The bottom panel of a column has no drag handle under it and
    /// ignores such a height (it comes back if the panel is moved up again).
    func ownHeight(_ p: Panel, last: Bool) -> Double? {
        last ? nil : m.layoutStore.panelHeights[p.rawValue]
    }

    /// How a panel takes part in its column (see `ColumnStack`): the bottom panel takes whatever room is left;
    /// every other panel has a height of its own (its default, or what its gap was dragged to). Panels sized by
    /// their controls (Develop, White Balance) never get shorter than the controls.
    func sizing(_ p: Panel, last: Bool) -> PanelSizing {
        let hugs: Bool = { if case .intrinsic = size(of: p) { return true }; return false }()
        if last {
            switch size(of: p) {
            case .fixed(let h): return PanelSizing(height: nil, min: min(h, Self.squeezeMin))
            case .intrinsic: return PanelSizing(height: nil, min: 0, hugsContent: true)
            case .flexible: return PanelSizing(height: nil, min: p == .looks ? 230 : 150)
            }
        }
        if let h = ownHeight(p, last: false) { return PanelSizing(height: h, min: hugs ? 0 : min(h, Self.squeezeMin), hugsContent: hugs) }
        switch size(of: p) {
        case .fixed(let h): return PanelSizing(height: h, min: min(h, Self.squeezeMin))
        case .intrinsic: return PanelSizing(height: nil, min: 0, hugsContent: true)
        case .flexible: return PanelSizing(height: p == .looks ? 420 : 300, min: Self.squeezeMin)   // Folders / LUT higher up
        }
    }

    /// When the column is too short, panels give height back down to this (their contents scroll inside the box).
    static let squeezeMin: CGFloat = 80

    /// Each gap resizes only the panel above it; the bottom panel takes what is left.
    @ViewBuilder func panelStack(_ visible: [Panel]) -> some View {
        let layout = m.layoutStore
        ColumnStack {
            ForEach(Array(visible.enumerated()), id: \.element) { i, p in
                let last = i + 1 == visible.count
                panelView(p)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)   // exactly the height given
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layout.measuredHeights[p.rawValue] = Double($0) }
                    .overlay(alignment: .bottom) {
                        if !last {                                              // none under the bottom panel
                            PanelGapHandle(store: layout, target: p.rawValue, sign: 1)
                                .frame(height: 8).offset(y: 4)                  // sits on the 6 pt gap between the cards
                        }
                    }
                    .zIndex(Double(visible.count - i))                         // the handle stays above the next panel
                    .layoutValue(key: PanelSizing.self, value: sizing(p, last: last))   // outermost, or ColumnStack can't see it
            }
        }
    }

    /// A folded column shown temporarily over the picture (mouse over its strip). Leaving it folds it away again;
    /// clicking the strip pins it open.
    @ViewBuilder func peekIfAny(_ side: String, _ layout: LayoutStore, left: Bool) -> some View {
        let tab = m.panelsHiddenByTab(side)
        if !tab.isEmpty { peek(side, layout, left: left, panels: tab, inset: 6) }
        else if (left ? layout.leftCollapsed : layout.rightCollapsed) && m.columnVisible(side) {
            peek(side, layout, left: left, inset: layout.stripWidth + 4)          // just inside the folded strip
        }
    }

    func edgeHover(_ layout: LayoutStore, left: Bool) -> some View {
        Color.clear.frame(width: 10).frame(maxHeight: .infinity).contentShape(Rectangle())
            .onHover { layout.hover(left: left, $0) }
    }

    func peek(_ side: String, _ layout: LayoutStore, left: Bool, panels: [Panel]? = nil, inset: Double) -> some View {
        column(side, width: left ? layout.leftWidth : layout.rightWidth, panels: panels)
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.28), radius: 18, x: left ? 6 : -6, y: 4)
            .padding(.vertical, 4)
            .padding(left ? .leading : .trailing, inset)
            .onHover { layout.hover(left: left, $0) }
            .transition(.move(edge: left ? .leading : .trailing).combined(with: .opacity))
            .zIndex(10)
    }

    @ViewBuilder func column(_ side: String, width: Double, panels: [Panel]? = nil) -> some View {
        let visible = panels ?? m.panels(in: side).filter { m.shown($0) && !m.isDetached($0) }
        if visible.isEmpty {
            // keeps an empty column droppable
            Color.clear.frame(width: m.layoutStore.emptyWidth)
                .dropDestination(for: String.self) { items, _ in
                    guard let r = items.first else { return false }
                    m.movePanel(r, to: side, before: nil); return true
                }
        } else {
            VStack(spacing: 0) {
                // Everything at its size when it fits; on a smaller screen the panels give up height (their contents
                // scroll inside them) rather than the whole column scrolling.
                panelStack(visible)
            }
            .frame(width: width, alignment: .leading)
            .clipped()                                   // never draws over the picture
            .dropDestination(for: String.self) { items, _ in
                guard let r = items.first else { return false }
                m.movePanel(r, to: side, before: nil); return true
            }
        }
    }

    func dropFiles(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                guard !urls.isEmpty else { return }
                m.load(urls)
            }
        }
        return true
    }

    // MARK: right-click menu for filmstrip and grid cells

    @ViewBuilder func photoMenu(_ url: URL) -> some View {
        let single = NSEvent.modifierFlags.contains(.option)          // ⌥ = this photo only (FastRawViewer)
        let ts = m.contextTargets(url, single: single)
        if ts.count > 1 { Button("\(ts.count) selected photos") {}.disabled(true); Divider() }
        Button("Open in single view") { m.open(url) }
        Menu("Rating") {
            ForEach(1...5, id: \.self) { i in Button(String(repeating: "★", count: i)) { m.setRating(i, on: ts) } }
            Button("No rating") { m.setRating(0, on: ts) }
            Button("Reject") { m.setRating(-1, on: ts) }
        }
        Menu("Label") {
            ForEach(labelNames, id: \.self) { n in Button(n) { m.setLabel(n, on: ts) } }
            Button("No label") { m.setLabel(nil, on: ts) }
        }
        Divider()
        Button(m.selection.contains(url) ? "Remove from selection" : "Add to selection") { m.click(url, command: true, shift: false) }
        Button("Select all shown") { m.selectAll() }
        Button("Deselect all") { m.clearSelection() }.disabled(!m.hasGroup)
        Divider()
        Button("Reveal in Finder") { m.revealInFinder(url) }
        Button(ts.count > 1 ? "Move \(ts.count) Photos to \(Model.rejectedFolderName)" : "Move to \(Model.rejectedFolderName)") { m.moveToRejected(ts) }
    }

}
