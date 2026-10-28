import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Liquid Glass

extension View {
    /// A rounded Liquid Glass card (macOS 26+); a material on older systems.
    @ViewBuilder func glassCard(_ radius: CGFloat = 14) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }

    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

extension View {
    /// A calm rounded card for grouping content on top of the window's glass.
    func softCard(_ radius: CGFloat = 14) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Panels

enum Panel: String, CaseIterable, Identifiable {
    case histogram, exif, stats, xmp, filmstrip, folders, favorites, filter, looks, whiteBalance, develop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .histogram: "Histogram"
        case .exif: "EXIF"
        case .stats: "Over/Underexposure Stats"
        case .xmp: "XMP Metadata"
        case .filmstrip: "Filmstrip"
        case .folders: "Folders"
        case .favorites: "Favorite Folders"
        case .filter: "Sort & Filter"
        case .looks: "LUT"
        case .whiteBalance: "White Balance"
        case .develop: "Develop (Exposure / Temp / Tint)"
        }
    }
    /// Function key, following FastRawViewer: F2 histogram … F5 XMP, F6 filmstrip, F7 folders, F8 the slot of Sort & Filter.
    var fKey: Int {
        switch self {
        case .histogram: 2
        case .exif: 3
        case .stats: 4
        case .xmp: 5
        case .filmstrip: 6
        case .folders, .favorites: 7
        case .looks, .filter: 8
        case .whiteBalance: 9
        case .develop: 10
        }
    }
}

extension Panel {
    /// ⇧ + function key (FastRawViewer: ⇧F7 favourite folders; here also ⇧F8 Sort & Filter, F8 being the LUT panel).
    var needsShift: Bool { self == .favorites || self == .filter }
}

func functionKey(_ n: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(UInt32(0xF703 + n))!))
}

private struct InDetachedWindowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var inDetachedWindow: Bool {
        get { self[InDetachedWindowKey.self] }
        set { self[InDetachedWindowKey.self] = newValue }
    }
}

extension View {
    /// Drag by the title bar to reorder or move between columns.
    @ViewBuilder func panelDraggable(_ p: Panel?, enabled: Bool) -> some View {
        if let p, enabled { self.draggable(p.rawValue) } else { self }
    }
}

/// How tall a panel wants to be in its column. `height` nil = take the room left (the bottom panel; or, with
/// `hugsContent`, its content's own height higher up). `min` is how far it may be squeezed when the column is short;
/// `hugsContent` panels are never squeezed below their content.
struct PanelSizing: LayoutValueKey, Equatable {
    static let defaultValue = PanelSizing(height: nil, min: 0)
    var height: Double?
    var min: Double
    var hugsContent = false
}

/// A side column: every panel at its own height from the top, the bottom one taking the rest. Only when that leaves
/// the bottom panel less than its minimum are the panels above squeezed, nearest the bottom first. So dragging a
/// gap changes the panel above it and the bottom one, nothing else, whenever the column has room.
struct ColumnStack: Layout {
    func heights(_ subviews: Subviews, width: CGFloat?, total: CGFloat) -> [CGFloat] {
        guard !subviews.isEmpty else { return [] }
        var want: [CGFloat] = [], mins: [CGFloat] = []
        for (i, v) in subviews.enumerated() {
            let s = v[PanelSizing.self]
            let content = s.hugsContent ? v.sizeThatFits(ProposedViewSize(width: width, height: nil)).height : 0
            let lo = Swift.max(CGFloat(s.min), content)
            mins.append(lo)
            want.append(i == subviews.count - 1 ? lo : Swift.max(lo, s.height.map { CGFloat($0) } ?? content))
        }
        let n = subviews.count - 1
        var h = want
        h[n] = Swift.max(mins[n], total - want[..<n].reduce(0, +))
        var over = h.reduce(0, +) - total
        var i = n - 1
        while over > 0.5 && i >= 0 {                                  // short column: squeeze from the bottom up
            let take = Swift.min(over, h[i] - mins[i])
            h[i] -= take; over -= take; i -= 1
        }
        return h
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = heights(subviews, width: proposal.width, total: 0).reduce(0, +)
        let total = proposal.height.map { $0.isFinite ? $0 : natural } ?? natural
        return CGSize(width: proposal.width ?? 0, height: total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (v, h) in zip(subviews, heights(subviews, width: bounds.width, total: bounds.height)) {
            v.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h
        }
    }
}

struct PanelBox<Trailing: View, Content: View>: View {
    @EnvironmentObject private var model: Model
    @Environment(\.inDetachedWindow) private var detached
    let title: String
    let panel: Panel?
    let onClose: () -> Void
    let trailing: Trailing
    let content: Content

    init(_ title: String, panel: Panel? = nil, onClose: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.panel = panel; self.onClose = onClose; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                trailing
                if let p = panel {
                    Button { if detached { model.reattach(p) } else { model.detach(p) } } label: {
                        Image(systemName: detached ? "arrow.down.backward.square" : "arrow.up.forward.square").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(detached ? "Put back into the main window" : "Open in its own window (drag the title bar to move it between columns)")
                }
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .panelDraggable(panel, enabled: !detached)
            content
            Spacer(minLength: 0)                 // the card fills a height set by dragging
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .softCard(14)
        .padding(3)
        .dropDestination(for: String.self) { items, _ in
            guard !detached, let p = panel, let raw = items.first else { return false }
            model.movePanel(raw, to: model.side(of: p), before: p)
            return true
        }
    }
}

extension PanelBox where Trailing == EmptyView {
    init(_ title: String, panel: Panel? = nil, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title, panel: panel, onClose: onClose, trailing: { EmptyView() }, content: content)
    }
}

/// Gives the window the system's own Liquid Glass (macOS 26: NSGlassEffectView, which follows the Clear / Tinted
/// choice in System Settings), or a behind-window blur on older systems, and reports the window.
struct WindowConfigurator: NSViewRepresentable {
    var onWindow: ((NSWindow) -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let v = Configurator()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}

    final class Configurator: NSView {
        var onWindow: ((NSWindow) -> Void)?
        private var installed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.isOpaque = false
            w.backgroundColor = .clear
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden                    // the filename is in the status bar; no text under the buttons
            w.styleMask.insert(.fullSizeContentView)
            if !installed, let content = w.contentView, let host = content.superview {
                installed = true
                let backdrop: NSView
                if #available(macOS 26, *) {
                    let g = NSGlassEffectView()
                    g.cornerRadius = 0
                    backdrop = g
                } else {
                    let v = NSVisualEffectView()
                    v.material = .underWindowBackground
                    v.blendingMode = .behindWindow
                    v.state = .active
                    backdrop = v
                }
                backdrop.frame = host.bounds                   // the whole window, title bar included
                backdrop.autoresizingMask = [.width, .height]
                host.addSubview(backdrop, positioned: .below, relativeTo: content)   // under the SwiftUI content
            }
            onWindow?(w)
        }
    }
}

/// A panel living in its own window; it shares the model with the main window.
struct DetachedPanelView: View {
    @ObservedObject var m: Model
    let panel: Panel

    var body: some View {
        ContentView(m: m).panelView(panel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 22)
            .background(Color(nsColor: .windowBackgroundColor).opacity(m.windowTint))
            .background(WindowConfigurator())
            .environmentObject(m)
            .environment(\.inDetachedWindow, true)
    }
}

// MARK: - Mouse wheel

/// Catches scroll-wheel events over a SwiftUI view without getting in the way of clicks and drags.
/// - `.picture`: the deltas go to the callback (pan when zoomed, otherwise step through the photos).
/// - `.horizontalStrip`: a plain vertical wheel scrolls the horizontal scroll view underneath sideways.
struct ScrollCatcher: NSViewRepresentable {
    enum Mode { case picture, horizontalStrip }
    var mode: Mode
    var onDelta: ((CGFloat, CGFloat, Bool) -> Void)? = nil
    /// `.picture`: trackpad pinch (magnification, point from the top-left, ended) and two-finger double-tap.
    var onPinch: ((CGFloat, CGPoint, Bool) -> Void)? = nil
    var onSmartMagnify: ((CGPoint) -> Void)? = nil
    /// `.picture`: fingers down for a new scroll gesture, and swipe events (Magic Mouse, three-finger swipe).
    var onScrollBegan: (() -> Void)? = nil
    var onSwipe: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.mode = mode; v.onDelta = onDelta; v.onPinch = onPinch; v.onSmartMagnify = onSmartMagnify
        v.onScrollBegan = onScrollBegan; v.onSwipe = onSwipe
    }

    final class CatcherView: NSView {
        var mode: ScrollCatcher.Mode = .picture
        var onDelta: ((CGFloat, CGFloat, Bool) -> Void)?
        var onPinch: ((CGFloat, CGPoint, Bool) -> Void)?
        var onSmartMagnify: ((CGPoint) -> Void)?
        var onScrollBegan: (() -> Void)?
        var onSwipe: ((CGFloat) -> Void)?

        // Only wheel, pinch and swipe events are ours; clicks fall through to the SwiftUI views below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .scrollWheel: return self
            case .magnify, .smartMagnify, .swipe: return mode == .picture ? self : nil
            default: return nil
            }
        }

        private func topLeft(_ e: NSEvent) -> CGPoint {
            let p = convert(e.locationInWindow, from: nil)
            return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
        }

        override func magnify(with event: NSEvent) {
            guard mode == .picture, let onPinch else { return super.magnify(with: event) }
            let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            onPinch(ended ? 0 : event.magnification, topLeft(event), ended)
        }

        override func swipe(with event: NSEvent) {
            guard mode == .picture, let onSwipe else { return super.swipe(with: event) }
            onSwipe(event.deltaX)
        }

        override func smartMagnify(with event: NSEvent) {
            guard mode == .picture, let onSmartMagnify else { return super.smartMagnify(with: event) }
            onSmartMagnify(topLeft(event))
        }

        override func scrollWheel(with event: NSEvent) {
            switch mode {
            case .picture:
                if event.phase.contains(.began) || event.phase.contains(.mayBegin) { onScrollBegan?() }
                // trackpads send fine point deltas; a mouse wheel sends a few coarse lines
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                onDelta?(event.scrollingDeltaX * k, event.scrollingDeltaY * k, !event.momentumPhase.isEmpty)
            case .horizontalStrip:
                guard let sv = Self.horizontalScrollView(in: window?.contentView, at: event.locationInWindow) else {
                    super.scrollWheel(with: event); return
                }
                let raw = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
                let delta = event.hasPreciseScrollingDeltas ? raw : raw * 14      // mouse notches are tiny
                let clip = sv.contentView, doc = sv.documentView!
                var o = clip.bounds.origin
                o.x = min(max(o.x - delta, 0), max(0, doc.frame.width - clip.bounds.width))
                clip.scroll(to: o)
                sv.reflectScrolledClipView(clip)
            }
        }

        static func horizontalScrollView(in root: NSView?, at p: NSPoint) -> NSScrollView? {
            guard let root else { return nil }
            var best: NSScrollView?
            func walk(_ v: NSView) {
                if let sv = v as? NSScrollView, let doc = sv.documentView,
                   sv.convert(sv.bounds, to: nil).contains(p), doc.frame.width > sv.contentView.bounds.width + 1 {
                    best = sv
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            return best
        }
    }
}
