import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers


/// The bottom filmstrip. It follows the current photo through a `scrollPosition` binding: SwiftUI applies that after
/// layout, so it works on first appearance (restored photo at launch, back from the grid, F6) and when the list and
/// the current photo change in the same update (filter, rating with "hide rejected", folder load) — the cases where
/// a `scrollTo` fired from `onChange` found no target yet and was dropped. A deferred `scrollTo` is kept as a second
/// opinion; both agree on the destination. One-step moves animate, jumps and key repeats do not, so an interrupted
/// animation can never leave the strip somewhere else.
struct FilmstripView: View {
    @ObservedObject var m: Model
    @ObservedObject var thumbs: ThumbStore
    let menu: (URL) -> AnyView
    @StateObject private var strip = StripState()

    final class StripState: ObservableObject {
        @Published var position: URL?          // the cell at the centre; SwiftUI scrolls there when it changes
        var lastIndex: Int?
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(m.shownPhotos) { p in
                        FilmCell(photo: p, isCurrent: p.url == m.current, isSelected: m.selection.contains(p.url),
                                 image: thumbs.images[p.url], hovered: thumbs.hovered == p.url, store: thumbs,
                                 markBox: m.advancedSelection, onMark: { m.toggleMark(p.url) })
                            .equatable()
                            .id(p.url)
                            .onTapGesture {
                                m.click(p.url, command: NSEvent.modifierFlags.contains(.command), shift: NSEvent.modifierFlags.contains(.shift))
                            }
                            .contextMenu { menu(p.url) }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollPosition(id: $strip.position, anchor: .center)
            .overlay(ScrollCatcher(mode: .horizontalStrip))
            .onAppear { follow(proxy, animated: false) }
            .onChange(of: m.current) { _, _ in follow(proxy, animated: true) }
            .onChange(of: m.shownPhotos.count) { _, _ in follow(proxy, animated: false) }
        }
        .background(Color.black.opacity(0.25))
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let cur = m.current else { return }
        let index = m.shownPhotos.firstIndex { $0.url == cur }
        let oneStep = animated && strip.lastIndex != nil && index != nil && abs(index! - strip.lastIndex!) == 1
        strip.lastIndex = index
        let move = {
            strip.position = cur
            proxy.scrollTo(cur, anchor: .center)
        }
        // After the current layout pass, so cells that appeared in this same update already exist.
        DispatchQueue.main.async {
            if oneStep { withAnimation(.easeOut(duration: 0.15)) { move() } }
            else { var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { move() } }
        }
    }
}

/// The full list of simple XMP properties, shown on demand.
struct XMPFieldList: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(m.xmpShowFields ? "Hide all XMP properties" : "Show all XMP properties (\(m.xmpFields.count))") { m.xmpShowFields.toggle() }
                .controlSize(.small)
            if m.xmpShowFields {
                ForEach(Array(m.xmpFields.enumerated()), id: \.offset) { _, kv in
                    HStack(alignment: .firstTextBaseline) {
                        Text(kv.0).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(kv.1).textSelection(.enabled)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var m: Model

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open the last folder when the app starts", isOn: $m.openLastFolder)
                Toggle("Include subfolders when opening a folder", isOn: $m.includeSubfolders)
                    .onChange(of: m.includeSubfolders) { _, _ in m.includeSubfoldersChanged() }
            }
            Section("Looks") {
                Picker("LUT panel columns", selection: $m.lutColumns) {
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                Toggle("Show favourite looks only", isOn: $m.favoriteLooksOnly)
                Text("\(m.favoriteLooks.count) favourite look(s). Click the star on a look, or press L.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Selection") {
                Toggle("Advanced selection mode: single click does not ruin selection", isOn: $m.advancedSelection)
                Text(m.advancedSelection
                     ? "Click moves to a photo and keeps the selection. ⌘-click or the checkbox in a thumbnail's corner marks it."
                     : "Standard (Finder): click selects only that photo, ⌘-click adds or removes, ⇧-click selects a range.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("⇧-click: start of range", selection: $m.shiftRangeStart) {
                    Text("Last checked or unchecked").tag(0)
                    Text("Last checked").tag(1)
                    Text("Current photo").tag(2)
                    Text("Current photo / last checked or unchecked").tag(3)
                }
                .disabled(!m.advancedSelection)
                Picker("⇧-click: range expansion", selection: $m.shiftExpands) {
                    Text("Create new selection").tag(false)
                    Text("Expand existing selection").tag(true)
                }
                Text("⌘⇧-click does the other one.").font(.caption).foregroundStyle(.secondary)
                Picker("Grid: current photo not in the selection, keys act on", selection: $m.outsideCurrentActsOn) {
                    Text("Selected group").tag(0)
                    Text("Current photo").tag(1)
                    Text("Both").tag(2)
                }
            }
            Section("Window") {
                Picker("Theme", selection: $m.theme) {
                    Text("System").tag(0)
                    Text("Dark").tag(1)
                    Text("Light").tag(2)
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Window tint")
                    Slider(value: $m.windowTint, in: 0...0.8)
                    Text(m.windowTint == 0 ? "clear" : String(format: "%.0f %%", m.windowTint * 100)).monospacedDigit()
                }
                HStack {
                    Text("Photo stage")
                    Slider(value: $m.stageOpacity, in: 0...1)
                    Text(String(format: "%.0f %%", m.stageOpacity * 100)).monospacedDigit()
                }
                Button("Reset panel layout") { m.resetLayout() }
            }
            Section("Grid view") {
                HStack {
                    Text("Thumbnail size")
                    Slider(value: $m.gridCell, in: 120...360)
                    Text("\(Int(m.gridCell)) px").monospacedDigit()
                }
            }
            Section("Smart zoom (double-click, Z, status-bar zoom)") {
                Picker("Zoom to", selection: $m.smartZoomFactor) {
                    Text("1.5 × the fit size").tag(1.5)
                    Text("2 × the fit size (default)").tag(2.0)
                    Text("3 × the fit size").tag(3.0)
                    Text("Always 100 %").tag(0.0)
                }
                Text("Smart zoom = the smallest of 25 / 33 / 50 / 67 / 100 % that is at least this many times the fit-to-window size, never above 100 %. ⌘1 is always exactly 100 %.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Exposure keys (⌥+ / ⌥−, ⌥⌘ for the big step)") {
                Picker("Small step", selection: $m.smallEVStep) {
                    Text("0.1 EV").tag(0.1); Text("⅓ EV").tag(1.0 / 3); Text("0.5 EV").tag(0.5)
                }
                Picker("Big step", selection: $m.bigEVStep) {
                    Text("0.5 EV").tag(0.5); Text("1 EV").tag(1.0); Text("2 EV").tag(2.0)
                }
            }
            Section("Auto EV") {
                Picker("Metering", selection: $m.meteringMode) {
                    ForEach(MeteringMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Export") {
                HStack {
                    Text("HEIC quality")
                    Slider(value: $m.quality, in: 0.5...1)
                    Text(String(format: "%.2f", m.quality)).monospacedDigit()
                }
                Toggle("Copy the .xmp next to each export", isOn: $m.copySidecar)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 640, idealWidth: 740, minHeight: 640, idealHeight: 780)
    }
}

/// One row of the folder tree. Expansion lives in the model, so opening a folder anywhere (History, Favourites,
/// drag & drop, last folder at launch) unfolds the tree down to it and highlights it.
