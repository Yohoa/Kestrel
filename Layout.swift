import SwiftUI
import AppKit

// Window layout: resizable / foldable side columns and named layout presets (save / apply / reset).

/// Everything that makes up "the layout": which panel is in which column, which are hidden or torn off,
/// column widths, folded columns and the LUT thumbnail size.
struct LayoutSnapshot: Codable, Equatable {
    var layout: [String: [String]]
    var hidden: [String]
    var leftWidth: Double
    var rightWidth: Double
    var leftCollapsed: Bool
    var rightCollapsed: Bool
    var lutColumns: Int
    var detached: [String]?           // optional so presets saved before this field still load
    var heights: [String: Double]?    // panel heights set by dragging the gap between panels
}

@MainActor
final class LayoutStore: ObservableObject {
    static let minWidth: Double = 260, maxWidth: Double = 640
    static let defaultLeft: Double = 262, defaultRight: Double = 372
    /// Room always left for the picture when a column is widened.
    static let minPicture: Double = 420

    weak var model: Model?

    /// The main window is in full screen (F): the folded strips get slimmer there.
    @Published private(set) var fullScreen = false
    private var fullScreenObservers: [NSObjectProtocol] = []
    var stripWidth: Double { fullScreen ? 12 : 22 }

    init() {
        for (name, on) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
            fullScreenObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                MainActor.assumeIsolated {
                    guard let self, let w = n.object as? NSWindow, w === self.model?.mainWindow else { return }
                    withAnimation(Self.spring) { self.fullScreen = on }
                }
            })
        }
    }

    @Published var leftWidth: Double = LayoutStore.load("leftWidth", LayoutStore.defaultLeft) { didSet { if !dragging { saveWidths() } } }
    @Published var rightWidth: Double = LayoutStore.load("rightWidth", LayoutStore.defaultRight) { didSet { if !dragging { saveWidths() } } }
    /// While a splitter is dragged, widths are saved once at the end instead of on every mouse move.
    var dragging = false { didSet { if !dragging { saveWidths(); savePanelHeights() } } }
    private func saveWidths() { save("leftWidth", leftWidth); save("rightWidth", rightWidth) }
    @Published var leftCollapsed = UserDefaults.standard.bool(forKey: "leftCollapsed") { didSet { UserDefaults.standard.set(leftCollapsed, forKey: "leftCollapsed") } }
    @Published var rightCollapsed = UserDefaults.standard.bool(forKey: "rightCollapsed") { didSet { UserDefaults.standard.set(rightCollapsed, forKey: "rightCollapsed") } }
    @Published private(set) var presetNames: [String] = LayoutStore.loadPresets().keys.sorted()

    /// Panel heights the user set by dragging the gap under (or over) a panel; panels not listed keep their own size.
    @Published var panelHeights: [String: Double] = UserDefaults.standard.dictionary(forKey: "panelHeights") as? [String: Double] ?? [:] {
        didSet { if !dragging { savePanelHeights() } }
    }
    private func savePanelHeights() { UserDefaults.standard.set(panelHeights, forKey: "panelHeights") }
    static let minPanelHeight: Double = 60, maxPanelHeight: Double = 1200
    /// Last laid-out height of each panel, so a drag starts from what is on screen. Not published: measuring must
    /// not cause another layout pass.
    var measuredHeights: [String: Double] = [:]

    /// Full height of a panel's scrolling contents (Sort & Filter), so the box can be exactly that tall when there
    /// is room and shrink (its contents scrolling) when there isn't.
    @Published private(set) var contentHeights: [String: Double] = [:]
    func setContentHeight(_ p: String, _ h: Double) {
        if abs((contentHeights[p] ?? -1) - h) > 0.5 { contentHeights[p] = h }
    }

    func setPanelHeight(_ p: String, _ h: Double) {
        panelHeights[p] = min(max(h, Self.minPanelHeight), Self.maxPanelHeight).rounded()
    }

    private static func load(_ key: String, _ fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v == 0 ? fallback : min(max(v, minWidth), maxWidth)
    }
    private func save(_ key: String, _ v: Double) { UserDefaults.standard.set(v, forKey: key) }

    /// Clamped to 260…640 pt and so that the picture keeps at least `minPicture` pt.
    func setWidth(left: Bool, _ w: Double) {
        let windowWidth = Double(model?.mainWindow?.frame.width ?? 1500)
        let otherVisible = (left ? model?.rightVisible : model?.leftVisible) ?? true
        let otherCollapsed = left ? rightCollapsed : leftCollapsed
        let other = otherCollapsed ? stripWidth : (otherVisible ? (left ? rightWidth : leftWidth) + 8 : 14)
        let chrome: Double = 8 + 6 + 12                 // this splitter, picture padding, window padding
        let limit = max(Self.minWidth, min(Self.maxWidth, windowWidth - other - chrome - Self.minPicture))
        let c = min(max(w, Self.minWidth), limit)
        if left { leftWidth = c } else { rightWidth = c }
    }

    /// The springy motion used for folding, unfolding and peeking.
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.78)

    func toggleCollapsed(left: Bool) {
        withAnimation(Self.spring) {
            if left { leftCollapsed.toggle(); peekLeft = false } else { rightCollapsed.toggle(); peekRight = false }
            fitToWindow()
        }
    }

    func setCollapsed(left: Bool, _ v: Bool) {
        withAnimation(Self.spring) {
            if left { leftCollapsed = v; peekLeft = false } else { rightCollapsed = v; peekRight = false }
        }
    }

    // MARK: peek — a folded column slides out over the picture while the mouse is near its edge

    @Published var peekLeft = false
    @Published var peekRight = false
    private var peekWork: [Bool: DispatchWorkItem] = [:]

    /// Mouse entered / left the folded strip or the peeking column. Opens after a short hover (passing by doesn't
    /// count) and closes a moment after the mouse leaves both, so moving from the strip into the column is smooth.
    func hover(left: Bool, _ inside: Bool) {
        peekWork[left]?.cancel()
        let open = left ? peekLeft : peekRight
        guard inside != open else { return }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(inside ? Self.spring : .spring(response: 0.28, dampingFraction: 0.9)) {
                if left { self?.peekLeft = inside } else { self?.peekRight = inside }
            }
        }
        peekWork[left] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.12 : 0.3), execute: w)
    }

    /// Pulled this far below the minimum width while dragging, a column folds itself.
    static let foldThreshold: Double = 170

    /// What one side takes besides the picture: folded strip, column + splitter, or the empty drop zone.
    private func sideWidth(left: Bool) -> Double {
        let visible = (left ? model?.leftVisible : model?.rightVisible) ?? true
        guard visible else { return 14 }
        if left ? leftCollapsed : rightCollapsed { return stripWidth }
        return (left ? leftWidth : rightWidth) + 8
    }

    /// Keeps the picture at least `minPicture` wide when the window shrinks: narrows the right column, then the left,
    /// down to their minimum, then folds the right column, then the left. Columns never overlap the picture.
    func fitToWindow() {
        guard let w = model?.mainWindow?.frame.width else { return }
        let room = Double(w) - 6 - 12 - Self.minPicture
        func excess() -> Double { sideWidth(left: true) + sideWidth(left: false) - room }
        if excess() > 0, !rightCollapsed { rightWidth = max(Self.minWidth, rightWidth - excess()) }
        if excess() > 0, !leftCollapsed { leftWidth = max(Self.minWidth, leftWidth - excess()) }
        if excess() > 0, !rightCollapsed, model?.rightVisible ?? true { withAnimation(Self.spring) { rightCollapsed = true } }
        if excess() > 0, !leftCollapsed, model?.leftVisible ?? true { withAnimation(Self.spring) { leftCollapsed = true } }
    }

    // MARK: presets

    private static let presetsKey = "layoutPresets"

    private static func loadPresets() -> [String: LayoutSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let d = try? JSONDecoder().decode([String: LayoutSnapshot].self, from: data) else { return [:] }
        return d
    }

    private func storePresets(_ d: [String: LayoutSnapshot]) {
        if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: Self.presetsKey) }
        presetNames = d.keys.sorted()
    }

    func snapshot(of m: Model) -> LayoutSnapshot {
        LayoutSnapshot(layout: m.layout, hidden: Array(m.hiddenPanels), leftWidth: leftWidth, rightWidth: rightWidth,
                       leftCollapsed: leftCollapsed, rightCollapsed: rightCollapsed, lutColumns: m.lutColumns,
                       detached: Array(m.detachedPanels), heights: panelHeights)
    }

    func apply(_ s: LayoutSnapshot, to m: Model) {
        m.layout = Model.sanitized(s.layout)                 // a preset from an older version still lists every panel
        m.saveLayout()
        for p in s.hidden { m.panelWindows[p]?.close() }     // hidden panels don't keep a floating window
        m.hiddenPanels = Set(s.hidden)
        leftCollapsed = s.leftCollapsed; rightCollapsed = s.rightCollapsed
        panelHeights = s.heights ?? [:]
        setWidth(left: true, s.leftWidth)               // clamped to this window, so the picture keeps its room
        setWidth(left: false, s.rightWidth)
        fitToWindow()
        m.lutColumns = min(max(s.lutColumns, 2), 3)
        let wantDetached = Set(s.detached ?? [])
        for p in Panel.allCases where m.shown(p) {
            let want = wantDetached.contains(p.rawValue)
            if want != m.isDetached(p) { if want { m.detach(p) } else { m.reattach(p) } }
        }
    }

    /// Asks for a name and stores the current layout under it (same name = overwrite).
    func saveCurrent(from m: Model) {
        let alert = NSAlert()
        alert.messageText = "Save Layout"
        alert.informativeText = "Name for the current panel layout (an existing name is replaced):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Layout \(presetNames.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var d = Self.loadPresets()
        d[name] = snapshot(of: m)
        storePresets(d)
        m.status = "Saved layout “\(name)”"
    }

    func applyPreset(_ name: String, to m: Model) {
        guard let s = Self.loadPresets()[name] else { return }
        apply(s, to: m)
        m.status = "Layout “\(name)”"
    }

    func deletePreset(_ name: String) {
        var d = Self.loadPresets()
        d[name] = nil
        storePresets(d)
    }

    /// Factory layout: default panels in default columns, default widths, nothing folded, hidden or floating.
    func reset(_ m: Model) {
        m.resetLayout()
        leftWidth = Self.defaultLeft; rightWidth = Self.defaultRight
        leftCollapsed = false; rightCollapsed = false
        panelHeights = [:]
        m.lutColumns = 3
        m.status = "Layout reset"
    }
}

// MARK: - Splitter (AppKit: exact cursor, drag to resize, click to fold)

final class SplitterNSView: NSView {
    var onBegin: (() -> Void)?
    /// Total movement since the mouse went down: rightwards, or downwards for a vertical (between-panels) handle.
    var onDrag: ((CGFloat) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onEnd: (() -> Void)?
    /// A handle between two stacked panels: up/down cursor, drags vertically, grip only while hovered.
    var vertical = false
    private var start: NSPoint = .zero
    private var moved = false
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { hovered = true }
    override func mouseExited(with e: NSEvent) { hovered = false }
    override func mouseDown(with e: NSEvent) { start = e.locationInWindow; moved = false; onBegin?() }
    override func mouseDragged(with e: NSEvent) {
        let d = vertical ? start.y - e.locationInWindow.y : e.locationInWindow.x - start.x   // window y grows upwards
        if abs(d) > 3 { moved = true }
        if moved { onDrag?(d) }
    }
    override func mouseUp(with e: NSEvent) {
        onEnd?()
        guard !moved else { return }
        if e.clickCount == 2 { onDoubleClick?() } else if e.clickCount == 1 { onClick?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        if vertical {
            guard hovered else { return }
            let grip = NSRect(x: bounds.midX - 18, y: bounds.midY - 1.5, width: 36, height: 3)
            NSColor.labelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            let grip = NSRect(x: bounds.midX - 1.5, y: bounds.midY - 18, width: 3, height: 36)
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// The gap between two panels in a column: drag it to make one of them taller or shorter, double-click to give
/// that panel its own size back. `target` is the panel that changes; `sign` is +1 when it sits above the gap.
struct PanelGapHandle: NSViewRepresentable {
    @ObservedObject var store: LayoutStore
    let target: String
    let sign: Double

    final class Coordinator { var startHeight: Double = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitterNSView {
        let v = SplitterNSView()
        v.vertical = true
        v.toolTip = "Drag to resize · double-click for the default size"
        configure(v, context.coordinator)
        return v
    }

    func updateNSView(_ v: SplitterNSView, context: Context) { configure(v, context.coordinator) }

    private func configure(_ v: SplitterNSView, _ c: Coordinator) {
        let store = self.store, target = self.target, sign = self.sign
        v.onBegin = { MainActor.assumeIsolated {
            c.startHeight = store.measuredHeights[target] ?? store.panelHeights[target] ?? 200   // what is drawn now
            store.dragging = true
        } }
        v.onDrag = { d in MainActor.assumeIsolated { store.setPanelHeight(target, c.startHeight + sign * Double(d)) } }
        v.onEnd = { MainActor.assumeIsolated { store.dragging = false } }
        v.onDoubleClick = { MainActor.assumeIsolated { withAnimation(LayoutStore.spring) { store.panelHeights[target] = nil } } }
    }
}

/// The thin handle between a side column and the picture: drag to resize, click to fold,
/// drag far below the minimum width to fold too.
struct SidebarSplitter: NSViewRepresentable {
    @ObservedObject var store: LayoutStore
    let left: Bool

    final class Coordinator { var startWidth: Double = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SplitterNSView {
        let v = SplitterNSView()
        v.toolTip = "Drag to resize · click to fold"
        configure(v, context.coordinator)
        return v
    }

    func updateNSView(_ v: SplitterNSView, context: Context) { configure(v, context.coordinator) }

    private func configure(_ v: SplitterNSView, _ c: Coordinator) {
        let store = self.store, left = self.left
        v.onBegin = { MainActor.assumeIsolated { c.startWidth = left ? store.leftWidth : store.rightWidth; store.dragging = true } }
        v.onEnd = { MainActor.assumeIsolated { store.dragging = false } }
        v.onDrag = { dx in
            MainActor.assumeIsolated {
                let w = left ? c.startWidth + Double(dx) : c.startWidth - Double(dx)
                if w < LayoutStore.foldThreshold {
                    store.setWidth(left: left, c.startWidth)        // unfolds to the width it had before the drag
                    store.setCollapsed(left: left, true)
                } else {
                    store.setWidth(left: left, w)
                }
            }
        }
        v.onClick = { MainActor.assumeIsolated { store.toggleCollapsed(left: left) } }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SplitterNSView, context: Context) -> CGSize? {
        CGSize(width: 8, height: proposal.height ?? 100)
    }
}

/// What a folded column leaves behind: a slim strip with a button to unfold it. Panels can still be dropped on it.
struct FoldedSidebar: View {
    @ObservedObject var store: LayoutStore
    let left: Bool

    var body: some View {
        VStack {
            if !store.fullScreen { Image(systemName: left ? "sidebar.left" : "sidebar.right").font(.system(size: 13)) }
            Spacer()
            Image(systemName: left ? "chevron.compact.right" : "chevron.compact.left").font(.system(size: 15))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        .frame(width: store.stripWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { store.toggleCollapsed(left: left) }          // the whole strip unfolds (pins)
        .onHover { store.hover(left: left, $0) }                      // hovering only peeks
        .help(left ? "Show the left panels (⌥⌘[)" : "Show the right panels (⌥⌘])")
        .dropDestination(for: String.self) { items, _ in
            guard let r = items.first, let m = store.model else { return false }
            m.movePanel(r, to: left ? "left" : "right", before: nil)
            store.toggleCollapsed(left: left)
            return true
        }
    }
}
