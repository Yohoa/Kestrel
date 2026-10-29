import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Left column panels: folders, favourites, EXIF, XMP.

extension ContentView {
    // MARK: left column

    var leftHeader: some View {
        VStack(spacing: 0) {
            HStack {
                Button { m.open() } label: { Label("Open…", systemImage: "folder") }.glassButton().focusable(false)
                    .help("Open a folder or RAW files (⌘O)")
                Menu {
                    ForEach(m.recentInputs, id: \.self) { u in
                        Button(u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent) { m.load([u]) }
                    }
                    Divider()
                    Button("Clear history") { m.clearHistory() }
                } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .disabled(m.recentInputs.isEmpty).help("Folders opened before")
            }
            .padding([.top, .horizontal], 6)
            Toggle("Include subfolders", isOn: $m.includeSubfolders)
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                .onChange(of: m.includeSubfolders) { _, _ in m.includeSubfoldersChanged() }
                .help("Also show the photos in the folders inside the one you open")
        }
    }

    var foldersPanel: some View {
        PanelBox("Folders", panel: .folders, onClose: { m.toggle(.folders) }, trailing: {
            Button { m.refreshFolderTree() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Refresh: list the folders and volumes again (new, renamed or removed folders)")
            Menu {
                Picker("Open a folder with", selection: $m.subfolderScope) {
                    Text("This folder only").tag(0)
                    ForEach([1, 2, 3, 4, 5, 8], id: \.self) { Text($0 == 1 ? "1 level of subfolders" : "\($0) levels of subfolders").tag($0) }
                    Text("All subfolders").tag(-1)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "gearshape").foregroundStyle(m.includeSubfolders ? Color.accentColor : .secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(m.subfolderScope == 0 ? "Opens this folder only" : m.subfolderScope < 0 ? "Includes all subfolders"
                  : "Includes \(m.subfolderScope) level(s) of subfolders")
        }) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        FolderTreeRoots(m: m)
                    }
                    .padding(4)
                }
                .onAppear { scrollTree(proxy) }
                .onReceive(NotificationCenter.default.publisher(for: .folderTreeCurrentRowAppeared)) { _ in scrollTree(proxy) }
                .onChange(of: m.currentFolder) { _, _ in scrollTree(proxy) }
            }
        }
    }

    /// Brings the current folder into view once its ancestors have been expanded and laid out.
    func scrollTree(_ proxy: ScrollViewProxy) {
        guard let f = m.currentFolder?.standardizedFileURL.path else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { withAnimation { proxy.scrollTo(f, anchor: .center) } }
    }

    var favoritesPanel: some View {
        PanelBox("Favorite folders", panel: .favorites, onClose: { m.toggle(.favorites) }, trailing: {
            Button { m.toggleCurrentFavorite() } label: {
                Image(systemName: m.currentIsFavorite ? "star.fill" : "star")
                    .foregroundStyle(m.currentIsFavorite ? Color.yellow : .secondary)
            }
            .buttonStyle(.plain).disabled(m.currentFolder == nil)
            .help(m.currentIsFavorite ? "Remove the current folder from favourites" : "Add the current folder to favourites")
        }) {
            Observing(FolderReach.shared) { reach in
                List(m.favorites, id: \.self) { u in favoriteRow(u, reach: reach) }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
            }
            .onAppear { FolderReach.shared.check(m.favorites) }
            .onChange(of: m.favorites) { _, f in FolderReach.shared.check(f) }
        }
    }

    /// A favourite that can't be reached (a share not connected, a drive unplugged) is greyed with a warning sign;
    /// clicking it says so in the row for a moment instead of opening an empty folder.
    func favoriteRow(_ u: URL, reach: FolderReach) -> some View {
        let off = reach.unreachable.contains(u), flash = reach.flashing == u, busy = reach.connecting == u
        let network = u.path.hasPrefix("/Volumes/")
        return HStack(spacing: 6) {
            Image(systemName: off ? (network ? "network.slash" : "folder.badge.questionmark") : "folder.fill")
                .foregroundStyle(off ? Color.orange : Color.accentColor)
                .frame(width: 18)
            if busy {
                ProgressView().controlSize(.mini)
                Text("Connecting…").foregroundStyle(.secondary).lineLimit(1)
            } else if flash {
                Text(network ? "Not connected" : "Folder not found")
                    .foregroundStyle(.orange).lineLimit(1).truncationMode(.tail)
                    .transition(.opacity)
            } else {
                Text(u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundStyle(off ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(flash ? Color.orange.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .help(off ? (network ? "Can't access \(u.path) right now. A click connects the network drive again (it asks for the password only if the keychain has none)."
                             : "Can't access \(u.path): the folder was moved, renamed or its drive unplugged.") + " Right-click to remove"
                  : "Click to open \(u.path). Right-click to remove")
        .onTapGesture { FolderReach.shared.open(u) { m.load([$0]) } }
        .contextMenu { Button("Remove") { m.removeFavorite(u) } }
    }

    var exifPanel: some View {
        PanelBox("EXIF", panel: .exif, onClose: { m.toggle(.exif) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(m.exifLines.enumerated()), id: \.offset) { _, kv in
                        HStack(alignment: .firstTextBaseline) {
                            Text(kv.0).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                            Text(kv.1).textSelection(.enabled)
                        }
                        .font(.system(size: 11))
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: XMP panel

    var xmpPanel: some View {
        PanelBox("XMP Metadata", panel: .xmp, onClose: { m.toggle(.xmp) }, trailing: { xmpMenu }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if m.current == nil {
                        Text("No photo").foregroundStyle(.secondary)
                    } else if m.xmpText == nil {
                        Text("No sidecar yet. It is created the first time you rate, label or develop this photo.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        xmpEditor
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var xmpMenu: some View {
        Menu {
            Button("Import exposure from the sidecar") { m.importXMPIntoSettings(includeWB: false) }
            Button("Import exposure and white balance") { m.importXMPIntoSettings(includeWB: true) }
            Button("Fill the draft from my develop settings") { m.fillXMPDraftFromSettings() }
            Divider()
            Button("Reveal sidecar in Finder") {
                if let c = m.current { NSWorkspace.shared.activateFileViewerSelecting([XMPFile.url(for: c)]) }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).fixedSize().disabled(m.current == nil)
        .help("Import from the sidecar, fill the draft, or show the .xmp in Finder")
    }

    var xmpEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { i in
                    Button { m.xmpDraft.rating = m.xmpDraft.rating == i ? 0 : i } label: {
                        Image(systemName: i <= m.xmpDraft.rating ? "star.fill" : "star").foregroundStyle(.orange)
                    }.buttonStyle(.plain).help("Draft rating: \(i) star\(i == 1 ? "" : "s") (click again to clear)")
                }
                Button { m.xmpDraft.rating = m.xmpDraft.rating == -1 ? 0 : -1 } label: {
                    Image(systemName: "xmark.circle\(m.xmpDraft.rating == -1 ? ".fill" : "")").foregroundStyle(.red)
                }.buttonStyle(.plain).help("Reject (rating −1)")
                Spacer()
                Picker("", selection: $m.xmpDraft.label) {
                    Text("No label").tag("")
                    ForEach(labelNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 100).help("Draft colour label")
            }
            xmpField("libraw:Exposure", "EV", $m.xmpDraft.exposure)
            xmpField("crs:Exposure2012", "EV", $m.xmpDraft.adobeExposure)
            xmpField("crs:Temperature", "K", $m.xmpDraft.temperature)
            xmpField("crs:Tint", "", $m.xmpDraft.tint)

            let pending = m.xmpPendingChanges
            VStack(alignment: .leading, spacing: 3) {
                Text("Review").font(.caption.bold())
                if pending.isEmpty {
                    Text("No pending changes").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(pending.enumerated()), id: \.offset) { _, c in
                        Text("\(c.tag): \(c.old) → \(c.new)").font(.system(size: 10, design: .monospaced))
                    }
                    HStack {
                        Button("Write to XMP") { m.writeXMPDraft() }.controlSize(.small).help("Save the changes above into the .xmp sidecar")
                        Button("Revert") { m.revertXMPDraft() }.controlSize(.small).help("Throw the draft away and show the sidecar as it is")
                    }
                }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 4))

            ForEach(m.xmpIssues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }

            if let line = m.xmpDevelopLine {
                Text(line).font(.caption2).foregroundStyle(.secondary).help("Kestrel's develop settings stored in this sidecar")
            }

            XMPFieldList(m: m)
        }
    }

    func xmpField(_ tag: String, _ unit: String, _ text: Binding<String>) -> some View {
        HStack {
            Text(tag).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 118, alignment: .leading)
                .help(Self.xmpTagTip(tag))
            TextField("", text: text).textFieldStyle(.roundedBorder).frame(width: 90).help(Self.xmpTagTip(tag))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func xmpTagTip(_ tag: String) -> String {
        switch tag {
        case "libraw:Exposure": "Exposure as FastRawViewer writes it (EV)"
        case "crs:Exposure2012": "Exposure as Lightroom / Camera Raw writes it (EV)"
        case "crs:Temperature": "White balance temperature as Lightroom writes it (K)"
        case "crs:Tint": "White balance tint as Lightroom writes it"
        default: tag
        }
    }

}
