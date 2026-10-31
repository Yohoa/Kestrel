import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import NetFS

@MainActor
final class FolderNode: ObservableObject, Identifiable, Hashable {
    nonisolated let url: URL
    nonisolated var id: URL { url }
    init(_ url: URL) { self.url = url }

    /// nil until listed, then the subfolders (empty when there are none or the folder can't be read).
    @Published private(set) var children: [FolderNode]?
    /// The folder couldn't be read (no permission, a network share that dropped).
    @Published private(set) var unreadable = false
    private var listing = false
    private var relistAgain = false

    func loadChildren() {
        guard children == nil else { return }
        relist()
    }

    /// This folder and every folder below it that has been listed already (opened in the tree), listed again.
    func relistLoaded() {
        guard let kids = children else { return }          // never listed: a collapsed row lists itself when it appears
        relist()
        kids.forEach { $0.relistLoaded() }
    }

    /// Lists the subfolders again (after they changed on disk); child nodes that are still there are kept.
    func relist() {
        guard !listing else { relistAgain = true; return }      // run again once the current listing is done
        listing = true
        let url = self.url
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let listed = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            let items = listed ?? []
            let dirs = items.filter {
                let v = try? $0.resourceValues(forKeys: Set(keys))
                return v?.isDirectory == true && v?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let old = Dictionary((self.children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
                    self.children = dirs.map { old[$0] ?? FolderNode($0) }
                    self.unreadable = listed == nil
                    self.listing = false
                    if self.relistAgain { self.relistAgain = false; self.relist() }
                }
            }
        }
    }

    nonisolated static func == (a: FolderNode, b: FolderNode) -> Bool { a.url == b.url }
    nonisolated func hash(into h: inout Hasher) { h.combine(url) }

    /// The tree starts with the folders in the home folder, then each mounted volume.
    static let home = FolderNode(FileManager.default.homeDirectoryForCurrentUser)
}

/// The mounted volumes other than the startup disk: external drives and network shares (SMB, AFP, NFS, WebDAV).
/// Taken from the system's list of mounts, not by reading /Volumes once, and refreshed whenever something is
/// mounted, unmounted or renamed, so a share connected while the app is open shows up at once.
@MainActor
final class FolderVolumes: ObservableObject {
    static let shared = FolderVolumes()
    @Published private(set) var nodes: [FolderNode] = []
    private(set) var network: Set<URL> = []

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in MainActor.assumeIsolated { FolderVolumes.shared.refresh() } }
        }
        refresh()
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeURLForRemountingKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            var vols: [URL] = [], net: Set<URL> = []
            for u in urls {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.volumeIsRootFileSystem == true || v?.volumeIsBrowsable == false { continue }
                vols.append(u.standardizedFileURL)
                if v?.volumeIsLocal == false {
                    net.insert(u.standardizedFileURL)
                    if let r = v?.volumeURLForRemounting { NetworkMount.remember(r, at: u.standardizedFileURL.path) }
                }
            }
            vols.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let old = Dictionary(self.nodes.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
                    self.network = net
                    self.nodes = vols.map { old[$0] ?? FolderNode($0) }
                }
            }
        }
    }
}

/// Network shares that went away (sleep, Wi-Fi change, a restart) are connected again on their own when a folder on
/// one is opened, the way Finder would if you clicked the server: the server address of every share seen mounted is
/// remembered (without a password; the keychain has that), and macOS asks for a password only if it has none.
enum NetworkMount {
    private static let key = "networkVolumes"          // "/Volumes/Name" -> "smb://user@server/share"

    static func remember(_ server: URL, at mountPoint: String) {
        var c = URLComponents(url: server, resolvingAgainstBaseURL: false)
        c?.password = nil
        guard let s = c?.url?.absoluteString else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if all[mountPoint] != s { all[mountPoint] = s; UserDefaults.standard.set(all, forKey: key) }
    }

    /// "/Volumes/Name" of a path on a volume, and the server it was mounted from, when that volume is not mounted now.
    static func missing(_ url: URL) -> (root: String, server: URL)? {
        let parts = url.pathKey.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        let root = "/Volumes/" + parts[1]
        guard NetworkMountCheck.notMounted(root),
              let s = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[root], let server = URL(string: s) else { return nil }
        return (root, server)
    }

    /// Mounts the share (no Finder window); `done` gets where it was mounted, nil if it could not be.
    static func mount(_ server: URL, _ done: @escaping @MainActor (String?) -> Void) {
        let open = NSMutableDictionary()
        open["UIOption"] = "AllowUI"                     // kNAUIOptionKey / kNAUIOptionAllowUI: a password prompt if needed
        var request: AsyncRequestID?
        let r = NetFSMountURLAsync(server as CFURL, nil, nil, nil, open, nil, &request, .main) { status, _, points in
            let first = (points as? [String])?.first
            MainActor.assumeIsolated { done(status == 0 || status == EEXIST ? first : nil) }   // EEXIST: it was mounted already
        }
        if r != 0 { DispatchQueue.main.async { MainActor.assumeIsolated { done(nil) } } }
    }

    /// The same folder under the place the share was mounted this time (usually the same "/Volumes/Name").
    static func moved(_ url: URL, from root: String, to point: String) -> URL {
        let p = url.pathKey
        let q = point + p.dropFirst(root.count)
        return URL(fileURLWithPath: q, isDirectory: !Model.isPhotoFile(q))
    }
}

/// Whether a volume is mounted, from the system's mount table (local, instant), never by looking at the
/// share itself — a stat on a mounted share's root is a network round trip, and on a share that dropped it can hang.
enum NetworkMountCheck {
    static func notMounted(_ root: String) -> Bool { !mountPoints().contains(root) }

    /// A path on a /Volumes/… volume that is not mounted (load() connects it, so it counts as there).
    static func onMissingVolume(_ url: URL) -> Bool {
        let parts = url.pathKey.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        return notMounted("/Volumes/" + parts[1])
    }

    static func mountPoints() -> Set<String> {
        var list: UnsafeMutablePointer<statfs>?
        // the kernel's table; MNT_NOWAIT: never asks a server. The _r_np form: called from more than one thread
        let n = getmntinfo_r_np(&list, MNT_NOWAIT)
        guard n > 0, let list else { return [] }
        defer { free(list) }
        return Set((0..<Int(n)).map { i in
            withUnsafeBytes(of: list[i].f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        })
    }
}

/// The top level of the folder tree; fills in once the home folder has been listed.
struct FolderTreeRoots: View {
    @ObservedObject var home = FolderNode.home
    @ObservedObject var volumes = FolderVolumes.shared
    let m: Model

    var body: some View {
        // The listing starts from a view that is always there: an onAppear on the ForEach itself never ran while it
        // had no rows yet, which was the case whenever no volume was mounted (the tree then stayed empty).
        VStack(alignment: .leading, spacing: 0) {
            ForEach((home.children ?? []) + volumes.nodes) { FolderTreeRow(m: m, tree: m.folderTree, node: $0, depth: 0) }
        }
        .onAppear { home.loadChildren() }
    }
}

extension Notification.Name {
    /// The current folder's row has just been added to the tree (its parent finished listing), so it can be scrolled to.
    static let folderTreeCurrentRowAppeared = Notification.Name("folderTreeCurrentRowAppeared")
}

/// Observes only the tree state and its folder, not the whole model (which changes all the time).
struct FolderTreeRow: View {
    let m: Model
    @ObservedObject var tree: FolderTreeState
    @ObservedObject var node: FolderNode
    let depth: Int

    var path: String { node.url.pathKey }             // never standardizedFileURL here: a stat per row per redraw

    /// Volumes at the top level get a drive or network icon, everything else a folder.
    var icon: String {
        let isCurrent = tree.current == path
        guard depth == 0, path.hasPrefix("/Volumes/") else { return isCurrent ? "folder.fill" : "folder" }
        return FolderVolumes.shared.network.contains(node.url) ? "network" : "externaldrive"
    }

    var body: some View {
        let expanded = tree.expanded.contains(path)
        let isCurrent = tree.current == path
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if node.children?.isEmpty == false {
                    Button {
                        if expanded { tree.expanded.remove(path) } else { tree.expanded.insert(path) }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 14, height: 14)
                            // a plain button only takes clicks on the glyph's own pixels: the whole square counts,
                            // reaching into the indent on the left and the row's padding above and below, without
                            // moving anything
                            .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 3))
                            .contentShape(Rectangle())
                            .padding(EdgeInsets(top: -3, leading: -10, bottom: -3, trailing: -3))
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Collapse" : "Show the subfolders")
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                Image(systemName: icon).foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                Text(node.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if tree.loading == path { ProgressView().controlSize(.mini).help("Opening…") }
                if node.unreadable {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 9)).foregroundStyle(.yellow)
                        .help("Can't read this folder. For a network share, check that it is still connected and that Kestrel may access network volumes (System Settings › Privacy & Security › Files & Folders).")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
            .help(node.url.path + " — click to open, right-click to refresh, rename or show in Finder")
            .onTapGesture { m.load([node.url]) }
            .contextMenu { menu(expanded: expanded) }
            .id(path)
            if expanded, let kids = node.children {
                ForEach(kids) { FolderTreeRow(m: m, tree: tree, node: $0, depth: depth + 1) }
            }
        }
        .onAppear {
            node.loadChildren()             // to know whether it gets a disclosure chevron
            if isCurrent { NotificationCenter.default.post(name: .folderTreeCurrentRowAppeared, object: nil) }
        }
    }

    @ViewBuilder func menu(expanded: Bool) -> some View {
        Button("Open") { m.load([node.url]) }
        if tree.includeSubfolders {
            Button("Open This Folder Only") { m.load([node.url], recursive: false) }
        } else {
            Button("Open Including Subfolders") { m.load([node.url], recursive: true) }
        }
        Divider()
        if node.children?.isEmpty == false {
            Button(expanded ? "Collapse" : "Expand") {
                if expanded { tree.expanded.remove(path) } else { tree.expanded.insert(path) }
            }
        }
        Button("Refresh Subfolders") { node.relist() }
        // not the top level: Desktop, Documents, a drive or a share are not for renaming from here
        Button("Rename…") { m.renameFolder(node.url) }.disabled(depth == 0)
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
    }
}

/// Which favourite folders can be opened right now. A share that is not connected (or a drive that is unplugged)
/// is checked off the main thread with a time limit, since a share that dropped can make a plain file check hang;
/// checked again when something is mounted or unmounted, and on every click.
@MainActor
final class FolderReach: ObservableObject {
    static let shared = FolderReach()
    @Published private(set) var unreachable: Set<URL> = []
    /// The row that was just clicked but could not be opened: it says so for a moment.
    @Published private(set) var flashing: URL?
    /// The row whose network drive is being connected.
    @Published private(set) var connecting: URL?
    private var flashWork: DispatchWorkItem?

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FolderReach.shared.check(FolderReach.shared.watched) }
            }
        }
    }

    private var watched: [URL] = []

    /// Checks these folders (the favourites) and remembers them for the next mount / unmount.
    func check(_ urls: [URL]) {
        watched = urls
        for u in urls { probe(u) { [weak self] ok in self?.set(u, ok) } }
    }

    /// Opens the folder if it can be reached, else flashes the row.
    func open(_ u: URL, _ load: @escaping (URL) -> Void) {
        guard connecting == nil else { return }
        if let (root, server) = NetworkMount.missing(u) {
            withAnimation(.easeOut(duration: 0.15)) { connecting = u }
            NetworkMount.mount(server) { [weak self] point in
                guard let self else { return }
                withAnimation(.easeIn(duration: 0.2)) { self.connecting = nil }
                guard let point else { self.set(u, false); self.flash(u); return }
                let there = NetworkMount.moved(u, from: root, to: point)
                self.probe(there) { [weak self] ok in
                    self?.set(u, ok)
                    if ok { load(there) } else { self?.flash(u) }
                }
            }
            return
        }
        // on a volume that is mounted: open it (the walk is off the main thread anyway; a share waking up can
        // take longer than the probe waits); the probe only updates the badge
        let parts = u.pathKey.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes", !NetworkMountCheck.notMounted("/Volumes/" + parts[1]) {
            load(u)
            probe(u) { [weak self] ok in self?.set(u, ok) }
            return
        }
        probe(u) { [weak self] ok in
            guard let self else { return }
            set(u, ok)
            if ok { load(u) } else { flash(u) }
        }
    }

    private func set(_ u: URL, _ ok: Bool) {
        if ok { if unreachable.contains(u) { unreachable.remove(u) } }
        else if !unreachable.contains(u) { unreachable.insert(u) }
    }

    private func flash(_ u: URL) {
        flashWork?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { flashing = u }
        let w = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.3)) { self?.flashing = nil } }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
    }

    /// Whether the folder exists and can be listed, answered within 2 s (no answer = not reachable).
    private var probing: Set<URL> = []

    private func probe(_ u: URL, _ report: @escaping @MainActor (Bool) -> Void) {
        // one at a time per folder: on a hung share, threads would otherwise pile up with every mount event
        guard !probing.contains(u) else { return }
        probing.insert(u)
        let done: @MainActor (Bool) -> Void = { [weak self] ok in self?.probing.remove(u); report(ok) }
        let lock = NSLock()
        var answered = false
        func answer(_ ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !answered else { return }
            answered = true
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
        DispatchQueue.global(qos: .utility).async {
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
                && FileManager.default.isReadableFile(atPath: u.path)
            answer(ok)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { answer(false) }
    }
}
