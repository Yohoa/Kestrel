import SwiftUI
import AppKit

// The Welcome screen (first launch, and Help ▸ Welcome to Kestrel) and the Tips screen (at every launch after the
// first, until "Don't Show Again"; Help ▸ Tips, and a switch in Settings).

extension Model {
    static let welcomeShownKey = "welcomeShown"
    static let tipsAtLaunchKey = "showTipsAtLaunch"

    var showTipsAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: Self.tipsAtLaunchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.tipsAtLaunchKey); objectWillChange.send() }
    }

    /// Once the window is up: Welcome the first time, a tip on later launches.
    func showLaunchScreen() {
        guard sheet == nil else { return }
        if !UserDefaults.standard.bool(forKey: Self.welcomeShownKey) {
            UserDefaults.standard.set(true, forKey: Self.welcomeShownKey)
            sheet = .welcome
        } else if showTipsAtLaunch {
            sheet = .tips
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Kestrel").font(.title2.bold())
                    Text("A fast RAW viewer for culling and grading camera RAW photos (Sony, Fujifilm, Canon, Nikon, Olympus, Panasonic, DNG and more), with LUT looks and 10-bit HEIC export.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                feature("folder", "Open a folder", "Open… or drop a folder on the window. Folders, network shares and drives are in the Folders panel.")
                feature("star", "Cull", "Rate, label and reject from the keyboard. Everything is saved in .xmp sidecars that Lightroom and FastRawViewer read too.")
                feature("camera.filters", "Grade", "Exposure, white balance and contrast in Develop; 11 picture-profile looks and 27 film LUTs are built in.")
                feature("square.and.arrow.up", "Export", "10-bit HEIC: right-click ▸ Quick Export for one photo, the Export button for many, each with its own look; ⌘C copies the edited photo.")
            }
            Divider()
            Text("The keys you will use most").font(.subheadline.bold())
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                key("← →", "previous / next photo", "1 – 5   X", "stars / reject")
                key("G", "grid ↔ single photo", "6 – 9", "colour labels")
                key("Z", "zoom (or double-click)", "Tab", "hide / show the panels")
                key("⌥⌘C   ⌘V", "copy / paste settings", "⇧⌘⌫", "move to _Rejected")
                key("⌘Z", "undo anything", "⌘K", "all keyboard shortcuts")
            }
            .font(.system(size: 12))
            HStack {
                Toggle("Show a tip at launch", isOn: Binding(get: { m.showTipsAtLaunch }, set: { m.showTipsAtLaunch = $0 }))
                    .toggleStyle(.checkbox).font(.caption)
                    .help("A tip each time Kestrel starts; Help ▸ Tips shows them any time")
                Spacer()
                Button("Open Folder…") { m.sheet = nil; DispatchQueue.main.async { m.openFolder(recursive: m.includeSubfolders) } }
                    .help("Close this and choose a folder of RAW files")
                Button("Start") { m.sheet = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func key(_ k1: String, _ t1: String, _ k2: String, _ t2: String) -> some View {
        GridRow {
            Text(k1).font(.system(size: 12, design: .monospaced).bold())
            Text(t1).foregroundStyle(.secondary)
            Text(k2).font(.system(size: 12, design: .monospaced).bold())
            Text(t2).foregroundStyle(.secondary)
        }
    }
}

/// One tip at a time; ‹ › to browse, Close, or Don't Show Again (turns off the tip at launch).
struct TipsView: View {
    @ObservedObject var m: Model
    final class Box: ObservableObject {
        @Published var index = UserDefaults.standard.integer(forKey: "nextTip") % Tips.all.count
    }
    @StateObject private var box = Box()

    var body: some View {
        let tip = Tips.all[box.index]
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Tip", systemImage: "lightbulb").font(.headline)
                Spacer()
                Text("\(box.index + 1) / \(Tips.all.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: tip.icon).font(.system(size: 26)).foregroundStyle(Color.accentColor).frame(width: 36)
                VStack(alignment: .leading, spacing: 5) {
                    Text(tip.title).font(.system(size: 14, weight: .semibold))
                    Text(tip.text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 84, alignment: .top)
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.help("Previous tip")
                Button { step(1) } label: { Image(systemName: "chevron.right") }.help("Next tip")
                Spacer()
                Button("Don't Show Again") { m.showTipsAtLaunch = false; close() }
                    .help("No tip at launch. Help ▸ Tips shows them again, and Settings can turn them back on.")
                Button("Close") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func step(_ d: Int) { box.index = (box.index + d + Tips.all.count) % Tips.all.count }

    /// The next launch starts with the tip after this one.
    private func close() {
        UserDefaults.standard.set((box.index + 1) % Tips.all.count, forKey: "nextTip")
        m.sheet = nil
    }
}

enum Tips {
    static let all: [(icon: String, title: String, text: String)] = [
        ("arrow.up.and.down", "Drag a value to change it",
         "Press on a number in Develop or White Balance and drag up or down. ⌥ is finer, ⇧ faster; double-click resets it. On an iPad (Sidecar), slide two fingers over it."),
        ("hand.tap", "Double-click a LUT to keep it",
         "A click tries a look; a double-click saves it to the photo on screen. Right-click a LUT to apply it to all selected photos."),
        ("eye", "Preview, Apply, Per photo",
         "The switch in the LUT header: Preview shows a look on every photo without saving anything, Apply saves the look you pick, Per photo shows each photo's own saved look."),
        ("doc.on.doc", "Copy the photo, or its settings",
         "⌘C copies the edited photo to paste anywhere. ⌥⌘C copies its settings; ⌘V pastes them onto the selection. Develop, white balance or LUT alone: the Copy ▾ menu, with shortcuts in Settings."),
        ("archivebox", "Move rejects out of the way",
         "⇧⌘⌫ moves the photo and its .xmp into a _Rejected folder next to it; ⌘Z moves it back. X only marks a photo as rejected."),
        ("sidebar.squares.left", "Only the photo",
         "Tab hides every panel; move the pointer to the left or right edge to peek at them. Tab again brings them back. F is full screen."),
        ("magnifyingglass", "Zooming",
         "Z or a double-click toggles fit and zoom; pinch on a trackpad; ⌥ or ⌘ + scroll zooms at the pointer; drag the Fit / % label in the status bar sideways."),
        ("hand.draw", "Swipe between photos",
         "Swipe two fingers left or right on the photo, or flick it sideways, to go to the next or previous one."),
        ("plusminus", "Exposure keys",
         "A sets exposure to 0 (A again brings it back), ⇧A meters the photo automatically, W steps through the white balances."),
        ("sun.max.trianglebadge.exclamationmark", "See what clips",
         "O shows blown highlights in red, U crushed shadows in blue. \\ compares the look with the plain Base look."),
        ("line.3.horizontal.decrease.circle", "Why are photos missing?",
         "Sort & Filter may be hiding some: V switches the filter off and on. The name field also finds a camera or lens name."),
        ("folder.badge.gearshape", "Subfolders",
         "The gear in Folders chooses whether a folder opens with its subfolders, and how many levels deep. ↻ lists the folders again."),
        ("checkmark.circle", "Selecting several photos",
         "⌘-click to add a photo, ⇧-click for a range, ⌘A for all. Ratings, labels, ⌘V and Export then act on the selection."),
        ("cursorarrow.click.2", "Right-click the photo",
         "Rating, label, auto exposure and white balance, one-click export, copy, undo and Move to _Rejected are all on the photo's right-click menu."),
        ("square.and.arrow.up", "Export in one click",
         "Right-click ▸ Quick Export saves a 10-bit HEIC where the Export settings say (a HEIC folder next to the RAW by default); Export As… asks where. The Export button exports many, each with its own look; rejected photos never."),
        ("macwindow.on.rectangle", "Two folders at once",
         "⌘N opens another Kestrel window of its own, for a second folder."),
        ("bell.badge", "Notices",
         "Short notices confirm what just happened, below the photo or in the LUT box. Turn off any kind in Settings ▸ Notices."),
        ("doc.text", "Your edits travel",
         "Ratings, labels and Kestrel's settings live in the .xmp next to each RAW, so Lightroom and FastRawViewer see your ratings too."),
        ("keyboard", "Every shortcut",
         "⌘K lists all keyboard shortcuts. Help ▸ Welcome to Kestrel shows the introduction again."),
    ]
}
