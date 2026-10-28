import SwiftUI
import AppKit

// Undo / redo for ratings, labels, XMP-panel writes and develop changes (⌘Z / ⇧⌘Z).
// Each step stores how to go back and how to go forward again; undoing a rating or a develop change writes the
// sidecar back through the same serial SidecarWriter, so the files and the screen stay in step.

@MainActor
final class UndoStore: ObservableObject {
    struct Item {
        let label: String
        var undos: [() -> Void]       // run in reverse order
        var redos: [() -> Void]
        var date: Date
        let key: String?              // continuous control on the same photos: merge (one slider drag = one step)
        let group: String?            // one action spread over several async results (Auto EV on a selection)
    }

    @Published private(set) var undoStack: [Item] = []
    @Published private(set) var redoStack: [Item] = []
    private(set) var applying = false
    private let limit = 300
    private let mergeWindow: TimeInterval = 1.5

    var undoTitle: String? { undoStack.last?.label }
    var redoTitle: String? { redoStack.last?.label }

    /// Records a step. Ignored while an undo / redo is being applied.
    func record(_ label: String, key: String? = nil, group: String? = nil,
                undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard !applying else { return }
        if let g = group, let top = undoStack.last, top.group == g {
            undoStack[undoStack.count - 1].undos.append(undo)       // same action, another photo
            undoStack[undoStack.count - 1].redos.append(redo)
            undoStack[undoStack.count - 1].date = Date()
        } else if group == nil, let k = key, let top = undoStack.last, top.key == k, Date().timeIntervalSince(top.date) < mergeWindow {
            undoStack[undoStack.count - 1].redos = [redo]           // keep the first "before", take the newest "after"
            undoStack[undoStack.count - 1].date = Date()
        } else {
            undoStack.append(Item(label: label, undos: [undo], redos: [redo], date: Date(), key: key, group: group))
            if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let it = undoStack.popLast() else { return }
        applying = true
        it.undos.reversed().forEach { $0() }
        applying = false
        redoStack.append(it)
    }

    func redo() {
        guard let it = redoStack.popLast() else { return }
        applying = true
        it.redos.forEach { $0() }
        applying = false
        var again = it
        again.date = .distantPast            // a redone step never merges with the next edit
        undoStack.append(again)
    }

    /// Opening another folder starts a fresh history.
    func clear() { undoStack.removeAll(); redoStack.removeAll() }
}

/// Edit menu: Undo / Redo for photo edits; inside a text field they go to the text, as the stock items would.
/// The items are never disabled: a disabled item would swallow ⌘Z inside text fields.
@MainActor
struct UndoCommands: Commands {
    @ObservedObject var store: UndoStore

    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(store.undoTitle.map { "Undo \($0)" } ?? "Undo") {
                if editingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { store.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            Button(store.redoTitle.map { "Redo \($0)" } ?? "Redo") {
                if editingText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { store.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}
