import SwiftUI
import AppKit

// Copy / paste of develop settings by part, and the shortcuts for it that Settings ▸ Shortcuts lets you set.
// ⌘C copies the edited photo (the picture itself); ⌘V pastes whichever settings were copied last.

/// The parts a settings copy can hold; ⌘V applies exactly the parts that were copied.
enum CopyPart: String, CaseIterable {
    case develop          // exposure, contrast, highlight recovery
    case whiteBalance     // Kelvin and tint, as numbers
    case look             // the look / LUT

    var title: String {
        switch self { case .develop: "Develop"; case .whiteBalance: "White Balance"; case .look: "LUT" }
    }
}

/// The actions with a shortcut that can be set in Settings.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case copyDevelop, copyWhiteBalance, copyLook, copyAll
    var id: String { rawValue }

    var title: String {
        switch self {
        case .copyDevelop: "Copy Develop (exposure, contrast, highlight recovery)"
        case .copyWhiteBalance: "Copy White Balance"
        case .copyLook: "Copy LUT / look"
        case .copyAll: "Copy all settings"
        }
    }

    var menuTitle: String {
        switch self {
        case .copyDevelop: "Copy Develop Settings"
        case .copyWhiteBalance: "Copy White Balance"
        case .copyLook: "Copy LUT"
        case .copyAll: "Copy All Settings"
        }
    }

    var parts: Set<CopyPart> {
        switch self {
        case .copyDevelop: [.develop]
        case .copyWhiteBalance: [.whiteBalance]
        case .copyLook: [.look]
        case .copyAll: Set(CopyPart.allCases)
        }
    }

    var defaultShortcut: Shortcut? {
        self == .copyAll ? Shortcut(keyCode: 8, key: "c", modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue) : nil   // ⌥⌘C
    }
}

/// A key with modifiers, matched by key code (⌥ changes the character a key types).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var key: String
    var modifiers: UInt

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection([.command, .shift, .option, .control]) }

    var display: String {
        let f = flags
        return (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "")
            + (f.contains(.command) ? "⌘" : "") + key.uppercased()
    }

    func matches(_ e: NSEvent) -> Bool {
        e.keyCode == keyCode && e.modifierFlags.intersection([.command, .shift, .option, .control]) == flags
    }

    /// ⌘C and ⌘V are taken (edited photo, paste settings); a shortcut must also have ⌘, ⌃ or ⌥, so plain keys
    /// stay the single-key shortcuts (stars, labels, Z, G …).
    var reservedReason: String? {
        if flags == .command, key == "c" || key == "v" { return "⌘C and ⌘V are fixed" }
        if flags.intersection([.command, .control, .option]).isEmpty { return "needs ⌘, ⌃ or ⌥" }
        return nil
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    /// Set by hand; an action not in here has its default; nil = deliberately none.
    @Published private var custom: [String: Shortcut?] = ShortcutStore.load() {
        didSet { if let d = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(d, forKey: "shortcuts") } }
    }

    private static func load() -> [String: Shortcut?] {
        guard let d = UserDefaults.standard.data(forKey: "shortcuts"),
              let m = try? JSONDecoder().decode([String: Shortcut?].self, from: d) else { return [:] }
        return m
    }

    func shortcut(_ a: ShortcutAction) -> Shortcut? {
        if let set = custom[a.rawValue] { return set }
        return a.defaultShortcut
    }

    func set(_ a: ShortcutAction, _ s: Shortcut?) { custom[a.rawValue] = .some(s) }
    func reset(_ a: ShortcutAction) { custom[a.rawValue] = nil }
    func isDefault(_ a: ShortcutAction) -> Bool { custom[a.rawValue] == nil }

    /// The action whose shortcut this key press is, if any.
    func action(for e: NSEvent) -> ShortcutAction? {
        ShortcutAction.allCases.first { shortcut($0)?.matches(e) == true }
    }

    /// Another action that has the same shortcut.
    func clash(_ a: ShortcutAction) -> ShortcutAction? {
        guard let s = shortcut(a) else { return nil }
        return ShortcutAction.allCases.first { $0 != a && shortcut($0) == s }
    }
}

/// Click, then press the shortcut. Esc cancels, Delete removes it.
struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> RecorderView { let v = RecorderView(); v.onChange = onChange; v.shortcut = shortcut; return v }
    func updateNSView(_ v: RecorderView, context: Context) { v.onChange = onChange; v.shortcut = shortcut; v.needsDisplay = true }

    final class RecorderView: NSView {
        var shortcut: Shortcut?
        var onChange: (Shortcut?) -> Void = { _ in }
        private var recording = false { didSet { needsDisplay = true } }
        private var hint: String?

        override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 22) }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { recording = true; hint = nil; window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool { recording = false; return true }

        // ⌘-keys come as key equivalents (the menus would take them otherwise)
        override func performKeyEquivalent(with e: NSEvent) -> Bool { recording ? take(e) : false }
        override func keyDown(with e: NSEvent) { if recording { _ = take(e) } else { super.keyDown(with: e) } }

        private func take(_ e: NSEvent) -> Bool {
            switch e.keyCode {
            case 53: recording = false; return true                                       // Esc
            case 51, 117: onChange(nil); recording = false; return true                   // Delete
            default: break
            }
            let key = (e.charactersIgnoringModifiers ?? "").lowercased()
            guard !key.isEmpty else { return true }
            let s = Shortcut(keyCode: e.keyCode, key: key, modifiers: e.modifierFlags.intersection([.command, .shift, .option, .control]).rawValue)
            if let why = s.reservedReason { hint = why; needsDisplay = true; NSSound.beep(); return true }
            onChange(s)
            recording = false
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = recording ? (hint ?? "Press a shortcut…") : (shortcut?.display ?? "None")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: shortcut == nil && !recording ? .regular : .medium),
                .foregroundColor: recording ? NSColor.labelColor : (shortcut == nil ? NSColor.secondaryLabelColor : NSColor.labelColor),
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

/// Settings ▸ Shortcuts.
struct ShortcutSettings: View {
    @ObservedObject var store: ShortcutStore

    var body: some View {
        Section("Shortcuts") {
            LabeledContent("Copy the edited photo") { Text("⌘C").foregroundStyle(.secondary) }
            LabeledContent("Paste the copied settings (only the copied parts, to the selection)") { Text("⌘V").foregroundStyle(.secondary) }
            ForEach(ShortcutAction.allCases) { a in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(a.title)
                        if let other = store.clash(a) {
                            Text("Same as “\(other.menuTitle)”").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 8)
                    if !store.isDefault(a) {
                        Button("Default") { store.reset(a) }.controlSize(.small)
                            .help(a.defaultShortcut.map { "Back to \($0.display)" } ?? "Back to none")
                    }
                    ShortcutRecorder(shortcut: store.shortcut(a)) { store.set(a, $0) }.frame(width: 110, height: 22).padding(.trailing, 2)
                }
            }
            Text("Click a field, then press the keys (with ⌘, ⌃ or ⌥). Delete removes a shortcut, Esc cancels.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
