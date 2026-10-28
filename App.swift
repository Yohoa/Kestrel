import SwiftUI
import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: Model?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false      // no window tabs (and no Show Tab Bar / Show All Tabs)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppDelegate.model?.flushForQuit() }       // pending develop saves are written first
        return .terminateNow
    }
}

@main
struct KestrelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("Kestrel") { ContentView(m: model) }
            .defaultSize(width: 1500, height: 940)
            .commands { PanelCommands(m: model); UndoCommands(store: model.undo) }
        Settings { SettingsView(m: model) }
    }
}

// MARK: - Output options

enum OutputMode: String, CaseIterable, Identifiable {
    case subfolder, sameFolder, custom, customPerPhoto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subfolder: "HEIC/ folder next to each RAW"
        case .sameFolder: "Same folder as each RAW"
        case .custom: "One chosen folder"
        case .customPerPhoto: "Chosen folder, one subfolder per photo"
        }
    }
    var needsFolder: Bool { self == .custom || self == .customPerPhoto }

    func directory(for raw: URL, custom: URL?, look: PPLook, group: Bool) -> URL {
        let src = raw.deletingLastPathComponent()
        var d: URL
        switch self {
        case .subfolder: d = src.appendingPathComponent("HEIC")
        case .sameFolder: d = src
        case .custom: d = custom ?? src.appendingPathComponent("HEIC")
        case .customPerPhoto:
            d = (custom ?? src.appendingPathComponent("HEIC")).appendingPathComponent(raw.deletingPathExtension().lastPathComponent)
        }
        return group ? d.appendingPathComponent(look.fileName) : d
    }
}

enum SheetKind: String, Identifiable {
    case export, help
    var id: String { rawValue }
}

enum ViewMode: String { case single, grid }

/// What the XMP panel shows for the current photo, and the edits queued but not yet written.
struct XMPDraft: Equatable {
    var rating = 0
    var label = ""            // "" = none
    var exposure = ""         // libraw:Exposure, EV
    var temperature = ""      // crs:Temperature
    var tint = ""             // crs:Tint
    var adobeExposure = ""    // crs:Exposure2012 (Adobe scale; only written when you ask)
}

// MARK: - Model

/// Zoom scale and pan of the single-photo view (see `Model.zoomState`).
/// A URL shared between the main thread and a background queue.
final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func get() -> URL? { lock.lock(); defer { lock.unlock() }; return url }
    func set(_ u: URL?) { lock.lock(); url = u; lock.unlock() }
}

final class StatusState: ObservableObject {
    @Published var status = "Open a folder of RAW files, or pick one in Folders."
    @Published var progress = 0.0
    @Published var exporting = false
}

/// The folder tree's view of the model: expanded folders, the current folder and the subfolders setting.
@MainActor
final class FolderTreeState: ObservableObject {
    @Published var expanded: Set<String> = []
    @Published var current: String?
    @Published var includeSubfolders = UserDefaults.standard.bool(forKey: "includeSubfolders")
}

final class ZoomState: ObservableObject {
    @Published var scale = 1.0
    @Published var offset = CGSize.zero
}

@MainActor
final class Model: ObservableObject {
    // Library
    @Published var library: [Photo] = []
    @Published var shownPhotos: [Photo] = [] {
        didSet {
            files = shownPhotos.map(\.url)
            fileIndex = Dictionary(files.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            exportTargetsCache = nil
        }
    }
    @Published var current: URL?
    @Published var selection: Set<URL> = [] {
        didSet {
            exportTargetsCache = nil
            if filter.selectedOnly && selection != oldValue { recomputeView() }   // "Selected" ticked in Sort & Filter
        }
    }
    @Published var currentFolder: URL? {
        didSet { folderTree.current = currentFolder?.standardizedFileURL.path; revealInTree(currentFolder) }
    }
    /// What the folder tree rows show; kept apart so the rows don't redraw on every change of the model.
    let folderTree = FolderTreeState()
    var expandedFolders: Set<String> {
        get { folderTree.expanded }
        set { folderTree.expanded = newValue }
    }

    /// File ▸ New Window: another Kestrel, as a process of its own, so the two windows share nothing but the settings
    /// on disk (one model per process: render queues, caches and the scan index are per app). It opens empty.
    func openNewInstance() {
        let c = NSWorkspace.OpenConfiguration()
        c.createsNewApplicationInstance = true
        c.arguments = ["-openLastFolderAtLaunch", "NO"]       // for that launch only, not saved
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.status = "Could not open a new window: \(error.localizedDescription)" } }
        }
    }

    /// The Folders panel's refresh: the home folder, the mounted volumes and every folder opened in the tree, listed
    /// again. What is expanded and the current folder stay as they are.
    func refreshFolderTree() {
        FolderNode.home.relistLoaded()
        FolderVolumes.shared.refresh()
        FolderVolumes.shared.nodes.forEach { $0.relistLoaded() }
        status = "Folders refreshed"
        notify(.foldersRefreshed, "Folders refreshed", icon: "arrow.clockwise")
    }

    /// Unfolds the folder tree down to `folder` (its parent folders; the folder itself stays as the user left it).
    func revealInTree(_ folder: URL?) {
        guard var u = folder?.standardizedFileURL.deletingLastPathComponent() else { return }
        var add: [String] = []
        while u.path != "/" && !u.path.isEmpty {
            add.append(u.path)
            u = u.deletingLastPathComponent()
        }
        let missing = add.filter { !expandedFolders.contains($0) }
        if !missing.isEmpty { expandedFolders.formUnion(missing) }
    }
    @Published var emptyHint: String?
    @Published var includeSubfolders = UserDefaults.standard.bool(forKey: "includeSubfolders") {
        didSet { UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders"); folderTree.includeSubfolders = includeSubfolders }
    }
    /// How many levels of subfolders "Include subfolders" goes down (FastRawViewer-style); 0 = all of them.
    @Published var subfolderDepth = UserDefaults.standard.integer(forKey: "subfolderDepth") {
        didSet { UserDefaults.standard.set(subfolderDepth, forKey: "subfolderDepth") }
    }

    /// The Folders panel's one choice for both settings: 0 = this folder only, n = n levels, -1 = all levels.
    var subfolderScope: Int {
        get { includeSubfolders ? (subfolderDepth == 0 ? -1 : subfolderDepth) : 0 }
        set {
            guard newValue != subfolderScope else { return }
            if newValue != 0 { subfolderDepth = max(newValue, 0) }
            includeSubfolders = newValue != 0
            includeSubfoldersChanged()                  // reload once
        }
    }
    @Published var filter = FilterState() {
        didSet {
            guard filter != oldValue else { return }
            var other = filter; other.name = oldValue.name
            if other == oldValue { scheduleRecompute(delay: 0.15) } else { recomputeView() }   // typing in the name field
        }
    }
    @Published var counts = FilterCounts()
    private var dateBuckets = DateBuckets()             // EXIF timestamp rows, fixed per folder load / refresh

    var filterContext: FilterContext {
        let st = states
        return FilterContext(buckets: dateBuckets, selection: selection, lookKey: { st[$0]?.look },
                             nameTest: filter.name.isEmpty ? nil : filter.nameTest)
    }
    func dateRange(_ b: DateBucket) -> String { dateBuckets.range(b) }

    func resetFilter() { filter.reset() }

    // Sort & Filter gear menu (FastRawViewer), remembered
    @Published var fpShowStatus = UserDefaults.standard.object(forKey: "filter.showStatus") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fpShowStatus, forKey: "filter.showStatus") }
    }
    @Published var fpShowSelected = UserDefaults.standard.object(forKey: "filter.showSelected") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fpShowSelected, forKey: "filter.showSelected") }
    }
    @Published var fpShowZeros = UserDefaults.standard.object(forKey: "filter.showZeros") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fpShowZeros, forKey: "filter.showZeros") }
    }
    @Published var fpHideSingle = UserDefaults.standard.bool(forKey: "filter.hideSingleValueGroups") {
        didSet { UserDefaults.standard.set(fpHideSingle, forKey: "filter.hideSingleValueGroups") }
    }
    @Published var fpNameField = UserDefaults.standard.bool(forKey: "filter.nameField") {
        didSet { UserDefaults.standard.set(fpNameField, forKey: "filter.nameField") }
    }
    @Published var fpCollapsed = Set(UserDefaults.standard.stringArray(forKey: "filter.collapsed") ?? []) {
        didSet { UserDefaults.standard.set(Array(fpCollapsed), forKey: "filter.collapsed") }
    }
    func toggleFilterGroup(_ id: String) {
        if fpCollapsed.contains(id) { fpCollapsed.remove(id) } else { fpCollapsed.insert(id) }
    }
    private var libIndex: [URL: Int] = [:]
    private var selectionAnchor: URL?

    // FastRawViewer selection modes (Settings ▸ Selection)
    /// Advanced mode: a plain click only moves the current photo; ⌘-click or the thumbnail checkbox marks.
    @Published var advancedSelection = UserDefaults.standard.bool(forKey: "advancedSelection") {
        didSet { UserDefaults.standard.set(advancedSelection, forKey: "advancedSelection") }
    }
    /// Advanced mode, ⇧-click range start: 0 last checked or unchecked, 1 last checked, 2 current photo,
    /// 3 current photo unless it was ⇧-clicked, then last checked or unchecked. Unknown → the first photo.
    @Published var shiftRangeStart = UserDefaults.standard.integer(forKey: "shiftRangeStart") {
        didSet { UserDefaults.standard.set(shiftRangeStart, forKey: "shiftRangeStart") }
    }
    /// ⇧-click adds the range to the selection instead of replacing it (⌘⇧-click does the opposite).
    @Published var shiftExpands = UserDefaults.standard.bool(forKey: "shiftExpands") {
        didSet { UserDefaults.standard.set(shiftExpands, forKey: "shiftExpands") }
    }
    /// Grid view, current photo outside the selection: keys act on 0 the selection, 1 the current photo, 2 both.
    @Published var outsideCurrentActsOn = UserDefaults.standard.integer(forKey: "outsideCurrentActsOn") {
        didSet { UserDefaults.standard.set(outsideCurrentActsOn, forKey: "outsideCurrentActsOn") }
    }
    private var lastChanged: URL?, lastChecked: URL?, lastShiftClicked: URL?

    /// The shown photos' URLs and their positions, kept with `shownPhotos` (they are read many times per redraw).
    private(set) var files: [URL] = []
    private var fileIndex: [URL: Int] = [:]
    private var exportTargetsCache: [URL]?
    func photo(_ url: URL?) -> Photo? { url.flatMap { libIndex[$0] }.map { library[$0] } }

    // Settings
    @Published var openLastFolder = UserDefaults.standard.object(forKey: "openLastFolderAtLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openLastFolder, forKey: "openLastFolderAtLaunch") }
    }

    // View mode: one photo or a grid of thumbnails (FastRawViewer "grid")
    @Published var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .single {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var gridCell = UserDefaults.standard.object(forKey: "gridCell") as? Double ?? 200 {
        didSet { UserDefaults.standard.set(gridCell, forKey: "gridCell") }
    }
    @Published var gridColumns = 4

    // Look
    @Published var ppID = 2
    @Published var lookMode = LookMode(rawValue: UserDefaults.standard.string(forKey: "lookMode") ?? "") ?? .apply {
        didSet {
            guard lookMode != oldValue else { return }
            UserDefaults.standard.set(lookMode.rawValue, forKey: "lookMode")
            if lookMode == .preview || chosenLook == nil { chosenLook = lookKey(ppID) }
            notify(.lookMode, lookMode.help, icon: lookMode == .preview ? "eye" : lookMode == .apply ? "square.and.pencil" : "photo.on.rectangle")
            syncLookFromState()
            if current != nil { refreshAll() }
        }
    }
    /// The look last chosen in the panel, by key: look ids are list positions and change when the LUT folder reloads.
    private var chosenLook: String?
    @Published var batchPPs: Set<Int> = [2]
    @Published var favoriteLooks: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favoriteLooks") ?? [])
    @Published var favoriteLooksOnly = false

    // Develop settings, per photo (saved into the .xmp sidecar: crs: for exposure/WB, arwexport: for the look)
    @Published var states: [URL: PhotoState] = [:]
    @Published var asShot: (temp: Float, tint: Float)?
    private var frvCache: [URL: PhotoState] = [:]
    private var dirtyURLs: Set<URL> = []
    /// Photos an undo took back to "never edited": their sidecar's arwexport: tags are removed on the next save.
    /// Only these — a photo merely missing from `states` is never stripped.
    private var undoneToNothing: Set<URL> = []
    private var saveTask: Task<Void, Never>?
    private var clipboard: PhotoState?
    @Published var meteringMode: MeteringMode = MeteringMode(rawValue: UserDefaults.standard.string(forKey: "meteringMode") ?? "") ?? .matrix {
        didSet { UserDefaults.standard.set(meteringMode.rawValue, forKey: "meteringMode") }
    }

    // Rendering
    @Published var preview: NSImage?
    @Published var previewError: String?
    @Published var overlay: NSImage?
    @Published var showOver = false
    @Published var showUnder = false
    @Published var thumbs: [Int: NSImage] = [:]
    @Published var hist: HistogramData?
    @Published var exifLines: [(String, String)] = []
    @Published var imageSize = ""

    // Zoom / pan
    /// Scale and pan change on every trackpad event; they live in their own object so that only the zoomed
    /// picture redraws, not the whole window.
    let zoomState = ZoomState()
    /// Fraction of full resolution, shown 1:1 on screen (1.0 = 100 %). Above 1 the 100 % render is enlarged.
    var zoomScale: Double { get { zoomState.scale } set { zoomState.scale = newValue } }
    var panOffset: CGSize { get { zoomState.offset } set { zoomState.offset = newValue } }
    static let maxZoom = 4.0
    /// Smart zoom = the smallest standard step that is at least this many times the fit-to-window size
    /// (capped at 100 %); 0 = always 100 %.
    @Published var smartZoomFactor = UserDefaults.standard.object(forKey: "smartZoomFactor") as? Double ?? 2.0 {
        didSet { UserDefaults.standard.set(smartZoomFactor, forKey: "smartZoomFactor") }
    }
    static let zoomSteps: [Double] = [0.25, 1.0 / 3, 0.5, 2.0 / 3, 1.0]
    @Published var zoomed = false
    /// The zoomed render and the scale it was rendered at; shown stretched to the current scale until the next
    /// render arrives, so zooming never flashes back to the fitted picture.
    @Published var zoomImage: NSImage?
    private var zoomImageScale = 0.0
    private var pinchRender: DispatchWorkItem?
    @Published var viewSize = CGSize(width: 800, height: 600)
    private var panStart = CGSize.zero
    private var dragging = false

    // White balance
    @Published var pickingWB = false

    // FastRawViewer-style actions
    var exposureMemory: [URL: Float] = [:]          // A: reset to 0, A again: restore
    var customWBMemory: [URL: (Float, Float?)] = [:] // W cycle returns to the photo's last custom WB
    var panelsBeforeHideAll: Set<String>?           // Tab: hide all panels / restore
    var lookBeforeCompare: Int?                     // \ : before / after against Base
    @Published var smallEVStep = UserDefaults.standard.object(forKey: "smallEVStep") as? Double ?? 1.0 / 3 {
        didSet { UserDefaults.standard.set(smallEVStep, forKey: "smallEVStep") }
    }
    @Published var bigEVStep = UserDefaults.standard.object(forKey: "bigEVStep") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(bigEVStep, forKey: "bigEVStep") }
    }

    // XMP panel
    @Published var xmpText: String?
    @Published var xmpFields: [(String, String)] = []
    @Published var xmpDraft = XMPDraft()
    @Published var xmpOriginal = XMPDraft()
    @Published var xmpShowFields = false
    @Published var xmpIssues: [String] = []
    @Published var xmpDevelopLine: String?

    // Export
    @Published var copySidecar = true
    @Published var quality = 0.85
    @Published var customOut: URL?
    @Published var outputMode: OutputMode = .subfolder
    @Published var groupByLook = false
    /// Status line and export progress live in `statusState`, which only the status bar observes: they change
    /// per exported photo and on many actions, and must not redraw the whole window each time.
    let statusState = StatusState()
    var status: String { get { statusState.status } set { statusState.status = newValue } }
    var progress: Double { get { statusState.progress } set { statusState.progress = newValue } }
    var exporting: Bool {
        get { statusState.exporting }
        set { guard newValue != exporting else { return }; objectWillChange.send(); statusState.exporting = newValue }   // menus too
    }
    @Published var sheet: SheetKind?
    private var exportTask: Task<Void, Never>?

    // Layout: which panels are in which column, which are torn off into their own windows
    static let defaultLayout: [String: [String]] = [
        "left": ["folders", "favorites", "filter", "exif", "xmp"],
        "right": ["histogram", "stats", "develop", "whiteBalance", "looks"],
    ]
    @Published var layout: [String: [String]] = Model.loadLayout()
    @Published var detachedPanels: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "detachedPanels") ?? [])
    var panelWindows: [String: NSWindow] = [:]
    weak var mainWindow: NSWindow?
    @Published var windowTint = UserDefaults.standard.object(forKey: "windowTint") as? Double ?? 0.0 {
        didSet { UserDefaults.standard.set(windowTint, forKey: "windowTint") }
    }
    /// 0 = follow the system, 1 = dark, 2 = light. Detached panel windows follow NSApp.appearance too.
    @Published var theme = UserDefaults.standard.integer(forKey: "theme") {
        didSet { UserDefaults.standard.set(theme, forKey: "theme"); applyTheme() }
    }
    func applyTheme() {
        NSApp?.appearance = theme == 1 ? NSAppearance(named: .darkAqua) : theme == 2 ? NSAppearance(named: .aqua) : nil
    }
    @Published var stageOpacity = UserDefaults.standard.object(forKey: "stageOpacity") as? Double ?? 0.45 {
        didSet { UserDefaults.standard.set(stageOpacity, forKey: "stageOpacity") }
    }

    // Layout
    @Published var hiddenPanels: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenPanels") ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenPanels), forKey: "hiddenPanels") }
    }
    @Published var lutColumns = max(2, min(3, UserDefaults.standard.integer(forKey: "lutColumns") == 0 ? 3 : UserDefaults.standard.integer(forKey: "lutColumns"))) {
        didSet { UserDefaults.standard.set(lutColumns, forKey: "lutColumns") }
    }
    @Published var favorites: [URL] = Model.loadHistory("favoriteFolders")

    // LUTs
    @Published var luts: [PPLook] = []
    @Published var lutFolder: URL?
    @Published var recentLUTFolders: [URL] = Model.loadHistory(Model.lutFoldersKey)
    private var lutURLs: [Int: URL] = [:]

    // Render pipeline (Render.swift): one decode per photo, caches so going back is instant, neighbours prefetched.
    /// True while the picture is the camera's embedded JPEG, shown until the real render lands.
    @Published var previewIsPlaceholder = false
    let filmThumbs = ThumbStore()                      // filmstrip / grid thumbnails; also the first placeholder
    private(set) var looksVersion = 0                  // bumped when the LUT list changes (look ids are indices)
    private let bakeCache = LRU<PhotoKey, BakedPhoto>(limit: 8)
    private let previewCache = LRU<PreviewKey, PreviewResult>(limit: 12)
    private let histCache = LRU<PhotoKey, HistogramData>(limit: 64)
    private let thumbCache = LRU<ThumbKey, [Int: NSImage]>(limit: 6)
    private let exifCache = LRU<URL, (lines: [(String, String)], size: String)>(limit: 128)
    private var renderedKey: PreviewKey?               // what the picture on screen was rendered for
    private var watchdogTask: Task<Void, Never>?
    private var previewRetries = 0
    private var zoomGen = 0
    var keyMonitor: Any?
    var clickMonitor: Any?
    let undo = UndoStore()
    let notices = NoticeCenter()

    /// A notice where the action happened (see Notices.swift); the status bar text is set by the caller as before.
    func notify(_ kind: NoticeKind, _ text: String, icon: String) { notices.post(kind, text, icon: icon) }
    let layoutStore = LayoutStore()
    private var layoutSink: AnyCancellable?

    struct PreviewResult { let image: NSImage; let overlay: NSImage? }
    struct ThumbKey: Hashable { let photo: PhotoKey; let looksVersion: Int }

    init() {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/ARWExport-LUTs").path
        if let p = UserDefaults.standard.string(forKey: Self.lutFolderKey) ?? (FileManager.default.fileExists(atPath: fallback) ? fallback : nil) {
            loadLUTFolder(URL(fileURLWithPath: p), remember: false)
        }
        AppDelegate.model = self
        layoutStore.model = self
        // Menus follow folding and presets; widths are observed by the columns alone (no whole-window redraw per drag pixel).
        layoutSink = Publishers.Merge3(layoutStore.$leftCollapsed.map { _ in () }, layoutStore.$rightCollapsed.map { _ in () },
                                       layoutStore.$presetNames.map { _ in () })
            .sink { [weak self] _ in self?.objectWillChange.send() }
        installKeyMonitor()
        LocalCache.trim()
        undo.onApply = { [weak self] label, redo in
            self?.notify(.undoRedo, (redo ? "Redid " : "Undid ") + label, icon: redo ? "arrow.uturn.forward" : "arrow.uturn.backward")
        }
        DispatchQueue.main.async { [weak self] in self?.applyTheme() }
        let torn = detachedPanels.compactMap(Panel.init(rawValue:))
        detachedPanels = []
        if !torn.isEmpty { DispatchQueue.main.async { [weak self] in torn.forEach { self?.detach($0) } } }
        if openLastFolder, let paths = UserDefaults.standard.stringArray(forKey: Self.lastOpenedKey) {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { DispatchQueue.main.async { [weak self] in self?.load(urls) } }
        }
    }

    var looks: [PPLook] { Looks.builtIn + luts }
    var look: PPLook { looks.first { $0.id == ppID } ?? Looks.builtIn[0] }

    /// Looks as the LUT panel lists them: favourites first, or only favourites.
    var visibleLooks: [PPLook] {
        let all = looks
        let fav = all.filter { isFavorite($0.id) }
        if favoriteLooksOnly { return fav }
        return fav.isEmpty ? all : fav + all.filter { !isFavorite($0.id) }
    }

    // MARK: favourite looks

    func isFavorite(_ id: Int) -> Bool { lookKey(id).map(favoriteLooks.contains) ?? false }

    func toggleFavoriteLook(_ id: Int) {
        guard let k = lookKey(id) else { return }
        if favoriteLooks.contains(k) { favoriteLooks.remove(k) } else { favoriteLooks.insert(k) }
        UserDefaults.standard.set(Array(favoriteLooks), forKey: "favoriteLooks")
        status = favoriteLooks.contains(k) ? "★ \(look(id).title) added to favourite looks" : "\(look(id).title) removed from favourite looks"
        notify(.favourite, favoriteLooks.contains(k) ? "\(look(id).title) added to favourites" : "\(look(id).title) removed from favourites",
               icon: favoriteLooks.contains(k) ? "star.fill" : "star.slash")
    }

    func look(_ id: Int) -> PPLook { looks.first { $0.id == id } ?? Looks.builtIn[0] }

    func tickFavoriteLooks() {
        let ids = looks.filter { isFavorite($0.id) }.map(\.id)
        if ids.isEmpty { status = "No favourite looks yet — click ☆ on a look"; return }
        batchPPs = Set(ids)
        status = "Ticked \(ids.count) favourite look(s) for export"
    }

    // MARK: panels

    func shown(_ p: Panel) -> Bool { !hiddenPanels.contains(p.rawValue) }
    func isDetached(_ p: Panel) -> Bool { detachedPanels.contains(p.rawValue) }

    func toggle(_ p: Panel) {
        if shown(p) {
            panelWindows[p.rawValue]?.close()                 // a torn-off panel closes its window first
            hiddenPanels.insert(p.rawValue)
        } else { hiddenPanels.remove(p.rawValue) }
    }

    func setAllPanels(visible: Bool) { hiddenPanels = visible ? [] : Set(Panel.allCases.map(\.rawValue)) }

    func panels(in side: String) -> [Panel] { (layout[side] ?? []).compactMap(Panel.init(rawValue:)) }
    func side(of p: Panel) -> String { layout["right"]?.contains(p.rawValue) == true ? "right" : "left" }
    func columnVisible(_ side: String) -> Bool { panels(in: side).contains { shown($0) && !isDetached($0) } }
    /// Tab mode: the panels of `side` that Tab hid (they peek out when the mouse goes to that edge).
    func panelsHiddenByTab(_ side: String) -> [Panel] {
        guard let saved = panelsBeforeHideAll else { return [] }
        return panels(in: side).filter { !saved.contains($0.rawValue) && !shown($0) && !isDetached($0) }
    }
    var leftVisible: Bool { columnVisible("left") }
    var rightVisible: Bool { columnVisible("right") }

    private static func loadLayout() -> [String: [String]] {
        guard let saved = UserDefaults.standard.dictionary(forKey: "panelLayout") as? [String: [String]] else { return defaultLayout }
        return sanitized(saved)
    }

    /// Unknown panels dropped, panels added since the layout was saved put back in their default column.
    static func sanitized(_ saved: [String: [String]]) -> [String: [String]] {
        let known = Set(Panel.allCases.map(\.rawValue))
        var left = (saved["left"] ?? []).filter(known.contains), right = (saved["right"] ?? []).filter(known.contains)
        right.removeAll(where: left.contains)
        let placed = Set(left + right)
        for p in (defaultLayout["left"] ?? []) where !placed.contains(p) { left.append(p) }
        for p in (defaultLayout["right"] ?? []) where !placed.contains(p) { right.append(p) }
        return ["left": left, "right": right]
    }

    func saveLayout() { UserDefaults.standard.set(layout, forKey: "panelLayout") }

    /// Drag a panel's title bar: put it before `target`, or at the end of `side` when `target` is nil.
    func movePanel(_ raw: String, to side: String, before target: Panel?) {
        guard Panel(rawValue: raw) != nil, raw != target?.rawValue else { return }
        var l = layout
        for k in l.keys { l[k]?.removeAll { $0 == raw } }
        var list = l[side] ?? []
        if let t = target, let i = list.firstIndex(of: t.rawValue) { list.insert(raw, at: i) } else { list.append(raw) }
        l[side] = list
        layout = l
        saveLayout()
    }

    func resetLayout() {
        layout = Self.defaultLayout
        hiddenPanels = hiddenPanels.filter { $0 == Panel.filmstrip.rawValue }
        for k in Array(panelWindows.keys) { panelWindows[k]?.close() }
        saveLayout()
    }

    // MARK: panels in their own windows

    private func windowSize(_ p: Panel) -> NSSize {
        switch p {
        case .histogram: NSSize(width: 400, height: 190)
        case .stats: NSSize(width: 320, height: 150)
        case .develop: NSSize(width: 400, height: 300)
        case .whiteBalance: NSSize(width: 400, height: 220)
        case .looks: NSSize(width: 440, height: 620)
        case .exif: NSSize(width: 320, height: 240)
        case .xmp: NSSize(width: 360, height: 460)
        case .folders: NSSize(width: 320, height: 520)
        case .favorites: NSSize(width: 320, height: 200)
        case .filter: NSSize(width: 320, height: 420)
        case .filmstrip: NSSize(width: 600, height: 160)
        }
    }

    /// Tears a panel off into an independent window (same live panel, shared state).
    func detach(_ p: Panel) {
        if let w = panelWindows[p.rawValue] { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize(p)),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = p.title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DetachedPanelView(m: self, panel: p))
        if !w.setFrameUsingName("ARWExport.panel." + p.rawValue) {
            if let main = NSApp.mainWindow { w.setFrameTopLeftPoint(NSPoint(x: main.frame.midX, y: main.frame.maxY - 80)) } else { w.center() }
        }
        w.setFrameAutosaveName("ARWExport.panel." + p.rawValue)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelWindowClosed(p) }
        }
        panelWindows[p.rawValue] = w
        detachedPanels.insert(p.rawValue)
        UserDefaults.standard.set(Array(detachedPanels), forKey: "detachedPanels")
        w.makeKeyAndOrderFront(nil)
    }

    /// Closing the window puts the panel back into the main window.
    private func panelWindowClosed(_ p: Panel) {
        panelWindows[p.rawValue] = nil
        detachedPanels.remove(p.rawValue)
        UserDefaults.standard.set(Array(detachedPanels), forKey: "detachedPanels")
    }

    func reattach(_ p: Panel) { panelWindows[p.rawValue]?.close() }

    func toggleGrid() {
        viewMode = viewMode == .grid ? .single : .grid
        zoomed = false
        zoomImage = nil; zoomImageScale = 0
        if viewMode == .single { scheduleRefresh() }
    }

    private var refreshTask: Task<Void, Never>?

    /// Holding → must not queue a decode per photo: only the photo you stop on is rendered.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshAll()
        }
    }

    // MARK: per-photo develop settings

    /// FastRawViewer keeps its exposure correction in libraw:Exposure. White balance is NOT imported
    /// automatically (FRV's Kelvin scale differs from Core Image's); the XMP panel can import it on demand.
    /// Normally seeded by `applyMetadata`; a photo whose metadata is still being read starts from the defaults
    /// (nothing renders or edits it before then), so this never reads the disk on the main thread for a step.
    private func frvInitial(_ url: URL) -> PhotoState {
        if let c = frvCache[url] { return c }
        if let i = libIndex[url], !library[i].metadataRead { return PhotoState() }
        var s = PhotoState()
        if let sc = Sidecar.load(for: url) {                // after an XMP edit cleared the cache
            if let d = sc.develop { s = d; savedDevelop.insert(url) }
            else { s.ev = sc.exposure ?? 0 }
        }
        frvCache[url] = s
        return s
    }

    /// Photos whose sidecar had this app's develop settings when read: their first undo puts those back.
    private var savedDevelop: Set<URL> = []

    func state(for url: URL?) -> PhotoState {
        guard let url else { return PhotoState() }
        if url == dragURL, let d = dragState { return d }          // a slider is being dragged on this photo
        return states[url] ?? frvInitial(url)
    }

    var currentState: PhotoState { state(for: current) }

    /// Every develop change goes through here, so it can be undone. `group` joins the results of one action that
    /// arrive one photo at a time (Auto EV on a selection) into one undo step.
    func edit(_ urls: [URL], group: String? = nil, _ change: (inout PhotoState) -> Void) {
        var before: [URL: PhotoState?] = [:], after: [URL: PhotoState?] = [:]
        var fields = Set<String>()
        ensureRead(urls)                                           // rare: an edit before the reader got there
        for u in urls {
            var s = state(for: u)
            let b = s
            change(&s)
            guard s != b else { continue }
            // First edit this session: settings already saved in the sidecar are put back on undo, not removed
            let prior: PhotoState? = states[u] ?? (!undoneToNothing.contains(u) && savedDevelop.contains(u) ? b : nil)
            before[u] = .some(prior)                               // nil inside = "no settings" on undo
            after[u] = s
            states[u] = s; dirtyURLs.insert(u); undoneToNothing.remove(u)
            if s.ev != b.ev { fields.insert("ev") }
            if s.temp != b.temp || s.tint != b.tint { fields.insert("wb") }
            if s.contrast != b.contrast { fields.insert("contrast") }
            if s.hl != b.hl || s.look != b.look { fields.insert("other") }
        }
        guard !after.isEmpty else { return }
        scheduleSave()
        if fields.contains("other") { recomputeViewKeepingCurrent() }        // With / Without LUT counts
        // A slider drag is one step: continuous controls on the same photos merge; looks, paste etc. never do.
        let f = fields.sorted().joined(separator: ",")
        let key = ["ev", "wb", "contrast"].contains(f) ? "develop:\(f):" + after.keys.map(\.path).sorted().joined(separator: "|") : nil
        let label = ["ev": "Exposure", "wb": "White Balance", "contrast": "Contrast"][f] ?? "Develop"
        undo.record(label, key: key, group: group,
                    undo: { [weak self] in self?.restoreStates(before) }, redo: { [weak self] in self?.restoreStates(after) })
    }

    /// Puts develop states back as they were (nil = never edited: the sidecar's arwexport: tags are removed).
    private func restoreStates(_ snap: [URL: PhotoState?]) {
        for (u, s) in snap {
            states[u] = s; dirtyURLs.insert(u)
            if s == nil { undoneToNothing.insert(u) } else { undoneToNothing.remove(u) }
        }
        scheduleSave()
        recomputeViewKeepingCurrent()
        lookBeforeCompare = nil
        syncLookFromState()
        refreshAll()
    }

    func editCurrent(_ change: (inout PhotoState) -> Void) { if let c = current { edit([c], change) } }

    // Slider drags: the value lives here while the knob moves (live preview, no undo step / save per tick),
    // and is committed as one edit on release.
    private var dragURL: URL?
    @Published private(set) var dragState: PhotoState?

    func beginSliderDrag() {
        guard dragState == nil, let c = current else { return }
        dragURL = c
        dragState = state(for: c)
    }

    func endSliderDrag() {
        guard let s = dragState, let u = dragURL else { return }
        dragState = nil; dragURL = nil
        edit([u]) { $0 = s }                    // one undo step and one save for the whole drag
    }

    /// Slider setter: during a drag only the transient value changes and the picture re-renders live.
    func adjust(_ change: (inout PhotoState) -> Void) {
        if dragState != nil, dragURL == current {
            change(&dragState!)
            refreshPreview(transient: true)
        } else {
            editCurrent(change)
        }
    }

    var exposure: Double {
        get { Double(currentState.ev) + 0 }          // + 0: a saved −0 shows as 0
        set { adjust { $0.ev = Float(newValue) } }
    }
    var temperature: Double {
        get { Double(currentState.temp ?? asShot?.temp ?? 5500) }
        set { adjust { $0.temp = Float(newValue) } }
    }
    var tint: Double {
        get { Double(currentState.tint ?? asShot?.tint ?? 0) }
        set { adjust { $0.tint = Float(newValue) } }
    }
    var highlightRecovery: Bool {
        get { currentState.hl }
        set { editCurrent { $0.hl = newValue } }
    }
    var wbIsCustom: Bool { currentState.temp != nil || currentState.tint != nil }

    func resetWB() { editCurrent { $0.temp = nil; $0.tint = nil } }
    func resetAdjustments() { editCurrent { let look = $0.look; $0 = PhotoState(); $0.look = look } }

    func applyWBPreset(_ p: WBPreset) {
        if p.temp == -1 { applyAutoWB(); return }
        editCurrent { $0.temp = p.temp; $0.tint = p.temp == nil ? nil : 0 }
        refreshAll()
    }

    /// Grey-world "Auto" white balance for the current photo.
    func applyAutoWB() {
        guard let url = current else { return }
        status = "Auto white balance…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = Decoded.autoWB(url)
            await MainActor.run {
                guard let self, self.current == url else { return }
                guard let r else {
                    self.status = "Auto white balance: not enough mid-tones to measure"
                    self.notify(.whiteBalance, "Auto WB: not enough mid-tones to measure", icon: "exclamationmark.triangle")
                    return
                }
                self.editCurrent { $0.temp = r.temp; $0.tint = r.tint }
                self.status = String(format: "WB: Auto %.0f K / %+.0f", r.temp, r.tint)
                self.notify(.whiteBalance, String(format: "Auto white balance %.0f K / %+.0f", r.temp, r.tint), icon: "thermometer.sun")
                self.refreshAll()
            }
        }
    }

    /// W, as in FastRawViewer: As Shot → Daylight → Auto → Custom (this photo's last custom WB) → As Shot.
    func cycleWB() {
        guard let url = current else { return }
        let s = currentState
        let isDaylight = s.temp == 5500 && (s.tint ?? 0) == 0
        if s.temp == nil {
            applyWBPreset(WBPreset.all.first { $0.temp == 5500 }!); status = "WB: Daylight"
        } else if isDaylight {
            applyAutoWB()
        } else if let c = customWBMemory[url], s.temp != c.0 || s.tint != c.1 {
            editCurrent { $0.temp = c.0; $0.tint = c.1 }; refreshAll(); status = "WB: Custom \(Int(c.0)) K"
        } else {
            if let t = s.temp, !isDaylight { customWBMemory[url] = (t, s.tint) }
            editCurrent { $0.temp = nil; $0.tint = nil }; refreshAll(); status = "WB: As Shot"
        }
    }

    func nudgeExposure(_ delta: Double) {
        exposure = (exposure + delta * 100).rounded() / 100
        refreshAll()
    }

    // Copy / paste of develop settings

    func copySettings() {
        guard let c = current else { return }
        ensureRead([c])
        clipboard = currentState
        status = "Copied settings (\(String(format: "%+.2f", currentState.ev)) EV\(currentState.temp.map { ", \(Int($0)) K" } ?? ""))"
        notify(.copyPaste, status, icon: "doc.on.doc")
    }

    func pasteSettings() {
        guard let c = clipboard else { status = "Nothing copied yet (⌘C)"; return }
        let ts = actionTargets()
        edit(ts) { $0 = c }
        status = "Pasted settings to \(ts.count) photo(s)"
        notify(.copyPaste, status, icon: "doc.on.clipboard")
        syncLookFromState()
        refreshAll()
    }

    /// Gives the photos the white balance the photo on screen shows, as numbers. "As shot" is not copied as such:
    /// every photo's as-shot is its own, so copying it would just reset the others to their camera's WB.
    func copyWhiteBalance(to urls: [URL]) {
        guard let c = current else { return }
        ensureRead([c])
        let st = currentState
        guard let t = st.temp ?? asShot?.temp else { status = "White balance not read yet, try again in a moment"; return }
        let ti = st.tint ?? asShot?.tint ?? 0
        let targets = urls.filter { $0 != c }
        guard !targets.isEmpty else { status = "Nothing to copy to: only this photo is selected"; return }
        edit(targets) { $0.temp = t; $0.tint = ti }
        status = String(format: "Copied %.0f K / %+.0f to %d photo(s)", t, ti, targets.count)
        notify(.whiteBalance, String(format: "White balance %.0f K / %+.0f copied to %d photo(s)", t, ti, targets.count), icon: "thermometer.sun")
    }

    func applyCurrentSettings(to scope: [URL]) {
        if let u = current { ensureRead([u]) }
        let c = currentState
        edit(scope) { $0 = c }
        status = "Applied current settings to \(scope.count) photo(s)"
        refreshAll()
    }

    /// Selection when there is one, otherwise the current photo.
    func actionTargets() -> [URL] {
        if selection.isEmpty { return current.map { [$0] } ?? [] }
        return files.filter(selection.contains)
    }

    /// Ratings, labels and reject from keys / menus / status bar: FastRawViewer acts on the group only in the grid;
    /// in single view always on the photo on screen. The right-click menu passes its own targets.
    func metadataTargets() -> [URL] {
        guard viewMode == .grid else { return current.map { [$0] } ?? [] }
        guard hasGroup, let c = current, !selection.contains(c) else { return actionTargets() }
        switch outsideCurrentActsOn {                       // FRV "If the current file is not in the group…"
        case 1: return [c]
        case 2: return files.filter { selection.contains($0) || $0 == c }
        default: return actionTargets()
        }
    }

    /// FastRawViewer disables batch XMP changes when two targets share a name (a.ARW + a.DNG → one a.xmp).
    private func sidecarConflict(_ ts: [URL]) -> Bool {
        guard ts.count > 1 else { return false }
        let stems = ts.map { $0.deletingPathExtension().path }
        guard Set(stems).count != stems.count else { return false }
        status = "XMP change skipped: two selected files share one sidecar name"
        return true
    }

    // MARK: persistence of develop settings

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSettings()
        }
    }

    /// Writes the changed photos' develop settings (arwexport: tags only) through the serial sidecar queue.
    /// The work is queued immediately, so quitting right after an edit still writes it.
    func flushSettings() {
        let urls = dirtyURLs
        dirtyURLs = []
        guard !urls.isEmpty else { return }
        let work = developWork(urls)
        SidecarWriter.shared.submit({ () -> [String] in
            var errors: [String] = []
            for (u, st) in work {
                do {
                    if let st { try XMPFile.writeDevelop(st, for: u) }
                    else { try XMPFile.write(DevelopXMP.removalChanges, for: u) }      // undone back to "never edited"
                }
                catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            return errors
        }, completion: { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let errors = (try? result.get()) ?? ["write failed"]
                if let e = errors.first { self.status = "Could not save settings to XMP — " + e + (errors.count > 1 ? " (+\(errors.count - 1) more)" : "") }
                if let c = self.current, urls.contains(c) { self.loadXMPPanel() }
            }
        })
    }

    /// What to write for each changed photo: its settings, or nil = remove ours (only after an undo to "never edited").
    private func developWork(_ urls: Set<URL>) -> [(URL, PhotoState?)] {
        urls.compactMap { u in
            if let s = states[u] { return (u, s) }
            return undoneToNothing.contains(u) ? (u, nil) : nil
        }
    }

    /// Called when the app quits: everything pending is written before the process ends.
    func flushForQuit() {
        saveTask?.cancel()
        let urls = dirtyURLs
        dirtyURLs = []
        let work = developWork(urls)
        SidecarWriter.shared.runSync {
            for (u, st) in work {
                if let st { try? XMPFile.writeDevelop(st, for: u) } else { try? XMPFile.write(DevelopXMP.removalChanges, for: u) }
            }
        }
        SidecarWriter.shared.drain()
    }

    // MARK: looks

    private func relativePath(_ u: URL) -> String {
        guard let f = lutFolder, u.path.hasPrefix(f.path + "/") else { return u.lastPathComponent }
        return String(u.path.dropFirst(f.path.count + 1))
    }

    func lookKey(_ id: Int) -> String? {
        if id < 100 { return "pp:\(id)" }
        return lutURLs[id].map { "lut:" + relativePath($0) }
    }

    func lookID(forKey key: String) -> Int? {
        if key.hasPrefix("pp:") { return Int(key.dropFirst(3)) }
        if key.hasPrefix("lut:") {
            let rel = String(key.dropFirst(4))
            if let hit = luts.first(where: { lutURLs[$0.id].map(relativePath) == rel }) { return hit.id }
            // moved within the folder, or another Mac's folder laid out differently: the same file name
            let name = (rel as NSString).lastPathComponent
            return luts.first { lutURLs[$0.id]?.lastPathComponent == name }?.id
        }
        return nil
    }

    func chooseLook(_ id: Int) {
        ppID = id
        chosenLook = lookKey(id)
        if lookMode != .preview, let k = chosenLook { editCurrent { $0.look = k } }
        refreshPreview()
        if zoomed { refreshZoom(force: true) }
    }

    /// LUT thumbnail ▸ Apply to Selected Photos: the look saved to each of them (one undo step), whatever the mode.
    func applyLook(_ id: Int, to urls: [URL]) {
        guard !urls.isEmpty, let k = lookKey(id) else { return }
        edit(urls) { $0.look = k }
        if let c = current, urls.contains(c) {
            ppID = id; chosenLook = k
            refreshPreview()
            if zoomed { refreshZoom(force: true) }
        }
        let name = look(id).title
        status = "\(name) saved to \(urls.count) photo(s)"
        notify(.lookSaved, "\(name) → \(urls.count) selected photo(s)", icon: "checkmark.circle.fill")
    }

    /// Double-click on a look: saved to the photo on screen whatever the panel's mode, with a notice in the panel.
    func applyLookToCurrent(_ id: Int) {
        guard let c = current, let k = lookKey(id) else { return }
        ppID = id
        chosenLook = k
        edit([c]) { $0.look = k }
        refreshPreview()
        if zoomed { refreshZoom(force: true) }
        let name = looks.first { $0.id == id }?.title ?? "Look"
        notify(.lookSaved, "\(name) → \(c.lastPathComponent)", icon: "checkmark.circle.fill")
    }

    /// The look to show for the current photo, by the LUT panel's mode.
    func syncLookFromState() {
        let saved = lookMode == .preview ? nil : currentState.look.flatMap(lookID(forKey:))
        let other = lookMode == .perPhoto ? 0 : chosenLook.flatMap(lookID(forKey:))     // 0 = Base
        if let id = saved ?? other, id != ppID { ppID = id }
    }


    // MARK: loading

    private static let lastOpenedKey = "lastOpenedPaths"

    func open() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "Choose RAW files (ARW, RAF, DNG) or folders"
        guard p.runModal() == .OK else { return }
        load(p.urls)
    }

    struct ScanResult {
        var photos: [Photo] = []
        var sawNonRAWFile = false
    }

    /// Lists the RAW files off the main thread. Nothing else is read here: sidecars and EXIF come later, in
    /// batches, from `MetadataReader` (FastRawViewer-style delayed loading), so a big folder opens at once.
    /// `depth` limits a recursive walk to that many levels of subfolders below each folder (0 = no limit).
    /// A long walk (a year of photos on a network share takes minutes) hands what it has found so far to `partial`
    /// every half second, so the photos can be looked at while the rest is still being listed.
    nonisolated static func scan(_ urls: [URL], recursive: Bool, depth: Int = 0, partial: (([URL]) -> Void)? = nil) -> ScanResult {
        let index = ScanIndex.shared
        index.reset()
        var found: [URL] = []
        var r = ScanResult()
        var unsent: [URL] = []
        var nextSend = Date().addingTimeInterval(0.3)          // a folder listed within this never shows half-loaded
        func send() {
            guard let partial, !unsent.isEmpty, Date() >= nextSend else { return }
            partial(unsent)
            unsent = []
            nextSend = Date().addingTimeInterval(max(0.5, Double(found.count) / 4000))   // less often as the list grows
        }
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                var opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
                if !recursive { opts.insert(.skipsSubdirectoryDescendants) }
                let limited = recursive && depth > 0
                // the listing brings these along at no extra cost (one bulk call per folder)
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: keys, options: opts)
                // A folder counts as listed (its sidecars all seen) only once the walk has left it: the walk goes
                // depth first, so a folder is done when an entry outside it comes up.
                var inside: [String] = [u.path]
                func leaveFolders(for f: URL) {
                    let parent = f.deletingLastPathComponent().path
                    while let last = inside.last, parent != last, !parent.hasPrefix(last + "/") {
                        index.folderListed(URL(fileURLWithPath: inside.removeLast()))
                    }
                }
                defer { for d in inside { index.folderListed(URL(fileURLWithPath: d)) } }
                while let f = e?.nextObject() as? URL {
                    if Task.isCancelled { return r }
                    leaveFolders(for: f)
                    if recursive, f.lastPathComponent == rejectedFolderName { e?.skipDescendants(); continue }   // open it to see them
                    let v = try? f.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory == true {
                        // e.level is 1 for what sits directly in `u`: the files inside a folder at level n are n levels down
                        if !recursive || (limited && (e?.level ?? 0) > depth) { e?.skipDescendants() } else { inside.append(f.path) }
                        continue
                    }
                    let ext = f.pathExtension.lowercased()
                    if ext == "xmp" { index.sidecarSeen(f) }
                    else if rawExtensions.contains(ext) {
                        found.append(f); unsent.append(f)
                        if let size = v?.fileSize, let date = v?.contentModificationDate { index.stampSeen(f, size: size, date: date) }
                    }
                    send()
                }
            } else if rawExtensions.contains(u.pathExtension.lowercased()) {
                found.append(u)
            } else { r.sawNonRAWFile = true }
        }
        r.photos = Array(Set(found)).sorted(by: pathOrder).map { Photo(url: $0) }
        return r
    }

    private var loadTask: Task<Void, Never>?
    private var scanTask: Task<ScanResult, Never>?
    private var loadSeq = 0
    private var streamedSeq = -1                  // the load whose photos are already showing while it scans
    private var scanDoneSeq = -1
    private var restoreName: String?              // the photo last looked at in this folder, not found yet
    private var autoSelected: URL?                // what was selected for the user; replaced by `restoreName` if it turns up

    func load(_ urls: [URL], recursive: Bool? = nil) {
        flushSettings()
        loadTask?.cancel()
        scanTask?.cancel()                          // stop the old walk too, not just ignore its result
        metaReader?.cancel()                        // and the old folder's metadata reader
        let rec = recursive ?? includeSubfolders
        let depth = subfolderDepth
        status = "Loading…"
        loadSeq += 1
        let seq = loadSeq
        let walk = Task.detached(priority: .userInitiated) { [weak self] in
            Model.scan(urls, recursive: rec, depth: depth, partial: { batch in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.scanned(batch, urls: urls, recursive: rec, seq: seq) } }
            })
        }
        scanTask = walk
        loadTask = Task { [weak self] in
            let scan = await walk.value
            guard !Task.isCancelled, let self, self.loadSeq == seq else { return }
            self.scanDoneSeq = seq
            if self.streamedSeq == seq { self.finishStreaming(scan) } else { self.finishLoad(urls, scan, recursive: rec) }
        }
    }

    /// Part of a long scan: the first part opens the folder, later ones join the list.
    private func scanned(_ batch: [URL], urls: [URL], recursive rec: Bool, seq: Int) {
        guard seq == loadSeq, scanDoneSeq != seq else { return }     // the final result has everything anyway
        if streamedSeq != seq {
            streamedSeq = seq
            finishLoad(urls, ScanResult(photos: Set(batch).sorted(by: Model.pathOrder).map { Photo(url: $0) }), recursive: rec, streaming: true)
        } else {
            appendScanned(batch.map { Photo(url: $0) })
        }
        status = "Scanning… \(library.count) RAW file(s) so far"
    }

    /// The library's order: by path, compared byte by byte (a Unicode-aware compare was most of the main thread's
    /// time when thousands of photos arrived from a scan).
    nonisolated static func pathOrder(_ a: URL, _ b: URL) -> Bool { a.path.utf8.lexicographicallyPrecedes(b.path.utf8) }

    /// Two lists already in `pathOrder`, merged in one pass.
    nonisolated static func merge(_ a: [Photo], _ b: [Photo]) -> [Photo] {
        var out: [Photo] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if pathOrder(b[j].url, a[i].url) { out.append(b[j]); j += 1 } else { out.append(a[i]); i += 1 }
        }
        out.append(contentsOf: a[i...]); out.append(contentsOf: b[j...])
        return out
    }

    private func appendScanned(_ photos: [Photo]) {
        let fresh = photos.filter { libIndex[$0.url] == nil }
        guard !fresh.isEmpty else { return }
        library = Model.merge(library, fresh.sorted { Model.pathOrder($0.url, $1.url) })
        libIndex = Dictionary(uniqueKeysWithValues: library.enumerated().map { ($1.url, $0) })
        metadataUnread += fresh.count
        metaReader?.add(fresh.map(\.url))
        recomputeView()                                  // keeps the current photo
        if emptyHint != nil, !shownPhotos.isEmpty { emptyHint = nil }
        if current == nil, let f = shownPhotos.first { select(f.url); autoSelected = f.url }
        // the photo last looked at in this folder turned up, and nothing else was chosen meanwhile
        if let name = restoreName, current == autoSelected, let u = shownPhotos.first(where: { $0.name == name })?.url {
            restoreName = nil
            select(u)
        }
    }

    private func finishStreaming(_ scan: ScanResult) {
        appendScanned(scan.photos)
        metaReader?.close()
        restoreName = nil
        status = "\(library.count) RAW file(s)" + (shownPhotos.count != library.count ? ", \(shownPhotos.count) shown" : "")
    }

    private func finishLoad(_ urls: [URL], _ scan: ScanResult, recursive rec: Bool, streaming: Bool = false) {
        if scan.photos.isEmpty && scan.sawNonRAWFile {                       // e.g. a JPG or .cube dropped on the picture
            status = "Nothing to open: that is not a RAW file (ARW, RAF, DNG)."
            return
        }
        if filter.selectedOnly { filter.selectedOnly = false }     // so clearing the selection below can't recompute mid-reset
        let photos = scan.photos
        let found = photos.map(\.url)
        library = photos
        libIndex = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($1.url, $0) })
        selection = []
        selectionAnchor = nil
        lastChanged = nil; lastChecked = nil; lastShiftClicked = nil
        flushSettings()                         // an edit made while the folder was scanning still belongs to the old states
        states = [:]
        undoneToNothing = []
        frvCache = [:]
        savedDevelop = []
        recomputeWork?.cancel(); recomputeWork = nil
        lastAppliedSeq = [:]
        metadataUnread = photos.count
        dateBuckets = DateBuckets()
        undo.clear()

        if let first = urls.first {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
            currentFolder = isDir.boolValue ? first : first.deletingLastPathComponent()
        }
        if !found.isEmpty {
            remember(&recentInputs, Self.inputsKey, urls)
            UserDefaults.standard.set(urls.map(\.path), forKey: Self.lastOpenedKey)
        }

        current = nil
        recomputeView(selectFirst: false)
        let lastName = currentFolder.flatMap { UserDefaults.standard.string(forKey: "last:" + $0.path) }
        let restore = lastName.flatMap { name in shownPhotos.first { $0.name == name }?.url }
        restoreName = streaming && restore == nil ? lastName : nil
        if found.isEmpty {
            let what = urls.first?.lastPathComponent ?? "the selection"
            emptyHint = rec ? "No ARW / RAF / DNG files in \(what)." : "No ARW / RAF / DNG files directly in \(what)."
            status = emptyHint ?? ""
            select(nil)
        } else {
            emptyHint = shownPhotos.isEmpty ? "All \(found.count) photos are hidden by the filter." : nil
            status = "\(found.count) RAW file(s)" + (shownPhotos.count != found.count ? ", \(shownPhotos.count) shown" : "")
            select(restore ?? shownPhotos.first?.url)
        }
        autoSelected = current
        startMetadataReader(found, open: streaming)
    }

    // MARK: delayed metadata loading (ratings, labels, saved develop settings, capture dates)

    /// Photos whose sidecar / EXIF have not been read yet; counts down as batches land.
    @Published var metadataUnread = 0
    private var metaReader: MetadataReader?

    /// Reads sidecars and EXIF dates in the background, in batches, starting around the current photo.
    private func startMetadataReader(_ files: [URL], open: Bool = false) {
        metaReader?.cancel()
        guard !files.isEmpty else { metaReader = nil; return }
        let reader = MetadataReader(files: files, open: open)
        metaReader = reader
        if let c = current { reader.prioritise(c) }
        // 4 readers: ~4.5× on 500 local files; on a network share each read mostly waits for the round trip, and
        // 8 read ~1.8× faster than 4 (measured on SMB)
        let readers = files.first.map(Storage.isSlow) == true ? 8 : 4
        for _ in 0..<readers { DispatchQueue.global(qos: .utility).async { [weak self] in
            while let batch = reader.next() {
                let results = batch.map { u -> (URL, PhotoMetadata) in
                    if Storage.isSlow(u) { RenderScheduler.shared.yieldToPreview() }   // the photo on screen is read first
                    return (u, PhotoMetadata.read(u))
                }
                if reader.isCancelled { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { [weak self] in
                        guard let self, self.metaReader === reader else { return }
                        self.applyMetadata(results)
                    }
                }
            }
        } }
    }

    /// One batch landed: update the library once, keep anything the user has already changed, recompute the view.
    private func applyMetadata(_ results: [(URL, PhotoMetadata)], reselect: Bool = true) {
        var landed = 0
        var landedURLs: Set<URL> = []
        for (u, m) in results {
            guard let i = libIndex[u] else { continue }
            if !library[i].metadataRead { landed += 1; landedURLs.insert(u) }
            var p = library[i]
            if lastAppliedSeq[u] == nil { p.rating = m.rating; p.label = m.label }   // a rating the user just wrote wins
            p.date = m.date
            p.gear = m.gear
            p.metadataRead = true
            library[i] = p
            var start = PhotoState(); start.ev = m.exposure ?? 0
            frvCache[u] = m.develop ?? start
            if m.develop != nil { savedDevelop.insert(u) } else { savedDevelop.remove(u) }
            if let d = m.develop, states[u] == nil, !dirtyURLs.contains(u), !undoneToNothing.contains(u) { states[u] = d }
        }
        metadataUnread = max(0, metadataUnread - landed)
        // the current photo's saved look just arrived (from whichever read got there first): render it now
        if let c = current, landedURLs.contains(c) {
            syncLookFromState()
            if viewMode == .single { refreshAll() }
        }
        // background batches land many times a second while a big folder is read: one recompute per 0.1 s
        if reselect { scheduleRecompute(delay: 0.1) } else { recomputeView(selectFirst: false) }
    }

    /// Reads one photo's sidecar right now (the selected photo must not wait for the background reader).
    private var recomputeWork: DispatchWorkItem?

    func scheduleRecompute(delay: Double) {
        guard recomputeWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.recomputeWork = nil; self?.recomputeView() }
        recomputeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Reads the photo's sidecar and EXIF off the main thread; rating, label and saved look land before the
    /// real render starts (the embedded preview shows meanwhile). Returns false when it was already read.
    private func readMetadataSoon(_ url: URL) -> Bool {
        guard let i = libIndex[url], !library[i].metadataRead else { return false }
        metaReader?.prioritise(url)
        Model.io.async { [weak self] in
            guard Model.ioCurrent.get() == url else { return }     // stepped past it (key repeat): skip the read
            let md = PhotoMetadata.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let i = self.libIndex[url], !self.library[i].metadataRead else { return }
                    self.applyMetadata([(url, md)], reselect: false)       // renders it if still current
                }
            }
        }
        return true
    }

    /// Small per-photo reads (sidecar, XMP text) that must not run on the main thread.
    static let io = DispatchQueue(label: "kestrel.io", qos: .userInitiated)
    /// The current photo, readable from `io`, so reads queued for photos already stepped past are skipped.
    static let ioCurrent = LockedURL()

    /// Rebuilds the filtered, sorted list; keeps the current photo (or moves to its neighbour if it disappeared).
    func recomputeView(selectFirst: Bool = true) {
        let oldFiles = files
        let oldIndex = current.flatMap { oldFiles.firstIndex(of: $0) }
        let ctx = filterContext
        shownPhotos = filter.ordered(library.filter { filter.matches($0, ctx) })
        let live = Set(shownPhotos.map(\.url))
        counts = FilterCounts(library, shown: live, ctx)
        let kept = selection.intersection(live)
        if kept != selection { selection = kept }
        if filter.selectedOnly && selection.isEmpty { filter.selectedOnly = false; return }   // nothing left to show: untick
        guard selectFirst else { return }
        if let c = current, live.contains(c) { return }
        if shownPhotos.isEmpty { select(nil); return }
        let i = min(oldIndex ?? 0, shownPhotos.count - 1)
        select(shownPhotos[i].url)
    }

    /// Sort & Filter ⟳: read the folder again.
    func rereadFolder() { if let f = currentFolder { load([f]) } }

    /// Sort & Filter ⟳: read every sidecar and EXIF date again (after another program changed them).
    func forceFullMetadataRead() {
        guard !library.isEmpty else { return }
        flushSettings()
        ScanIndex.shared.reset()                // another program may have added sidecars: look for every one
        lastAppliedSeq = [:]                    // re-import ratings/labels set in this session too
        for i in library.indices { library[i].metadataRead = false }
        metadataUnread = library.count
        dateBuckets = DateBuckets()
        recomputeView(selectFirst: false)
        startMetadataReader(library.map(\.url), open: streamedSeq == loadSeq && scanDoneSeq != loadSeq)   // still scanning
        status = "Reading metadata of \(library.count) photo(s)…"
    }

    func includeSubfoldersChanged() {
        if let f = currentFolder { load([f]) }
    }

    // MARK: navigation and selection

    var currentIndex: Int? { current.flatMap { fileIndex[$0] } }

    func step(_ delta: Int) {
        guard let i = currentIndex else { if let f = files.first { select(f) }; return }
        let j = min(max(i + delta, 0), files.count - 1)
        if j != i { select(files[j]) }
    }

    func goFirst() { if let f = files.first { select(f) } }
    func goLast() { if let l = files.last { select(l) } }

    /// Click on a filmstrip / grid cell: plain = go there; ⌘ = toggle in selection; ⇧ = range from the anchor.
    /// Click on a thumbnail. Standard mode (Finder): plain = go there and the selection becomes just that photo,
    /// kept as an empty set (= act on the current photo). Advanced mode (FastRawViewer default): plain = go there,
    /// the selection stays. Both: ⌘ = toggle the mark; ⇧ = range (replaces, or adds per Settings; ⌘⇧ = the other).
    /// Only a plain click moves the current photo.
    func click(_ url: URL, command: Bool, shift: Bool) {
        if shift, let j = files.firstIndex(of: url) {
            let i = rangeStart().flatMap { files.firstIndex(of: $0) } ?? 0          // unknown start → the first photo
            let range = Set(files[min(i, j)...max(i, j)])
            selection = shiftExpands != command ? selection.union(range) : range     // ⌘⇧ inverts the setting
            lastShiftClicked = url
        } else if command {
            toggleMark(url)
        } else if advancedSelection {
            lastShiftClicked = nil
            select(url)                                                              // the selection stays
        } else {
            selection = []
            selectionAnchor = url; lastChanged = url
            select(url)
        }
    }

    /// Marks or unmarks one photo (⌘-click, thumbnail checkbox, ⌘D).
    func toggleMark(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url); lastChecked = url }
        lastChanged = url
        selectionAnchor = url
    }

    private func rangeStart() -> URL? {
        guard advancedSelection else { return selectionAnchor ?? current }
        switch shiftRangeStart {
        case 1: return lastChecked
        case 2: return current
        case 3: return current != nil && current != lastShiftClicked ? current : lastChanged
        default: return lastChanged
        }
    }

    /// ⇧← / ⇧→ (⇧↑ / ⇧↓ in the grid): move and extend the range from the anchor.
    func extendSelection(_ delta: Int) {
        guard let c = current, let i = currentIndex, !files.isEmpty else { return }
        let a = selectionAnchor ?? c
        selectionAnchor = a
        let j = min(max(i + delta, 0), files.count - 1)
        select(files[j])
        if let ai = files.firstIndex(of: a) { selection = Set(files[min(ai, j)...max(ai, j)]) }
    }

    /// ⌘D / Select menu: (de)select the current photo, then move on (FastRawViewer "(De)select and move to next").
    func toggleCurrentSelection(thenStep delta: Int = 0) {
        guard let c = current, let i = currentIndex else { return }
        let j = i + delta
        let next = delta != 0 && files.indices.contains(j) ? files[j] : nil   // fixed first: "Selected" filtering may drop c
        toggleMark(c)
        if let next, next != current { select(next) }
    }

    func invertSelection() { selection = Set(files).subtracting(selection) }

    /// A marked set exists (otherwise actions use the current photo).
    var hasGroup: Bool { !selection.isEmpty }
    /// FastRawViewer's red "Sel": the photo on screen is one of the marked ones.
    var currentIsSelected: Bool { current.map(selection.contains) ?? false }

    /// Double-click in the grid opens the photo in single view.
    func open(_ url: URL) {
        if !advancedSelection { selection = [] }
        viewMode = .single                                         // first, so select shows and renders it
        select(url)
    }

    func selectAll() { selection = Set(files); selectionAnchor = nil }
    func clearSelection() { selection = []; selectionAnchor = current; status = "Selection cleared" }

    // MARK: ratings, labels (written to the .xmp, minimal diff)

    /// Photos a right-click acts on: the selection when the clicked photo is part of it, else just that photo.
    /// ⌥ held when the menu opened = that photo only (FastRawViewer).
    func contextTargets(_ url: URL, single: Bool = false) -> [URL] {
        !single && selection.contains(url) ? files.filter(selection.contains) : [url]
    }

    /// Reads the sidecars of targets the background reader hasn't reached, so "before" values (undo, toggles) are real.
    /// Reads now (on the main thread) whatever of `urls` the background reader hasn't reached; for actions that
    /// use a photo's saved settings and can't wait.
    func ensureRead(_ urls: [URL]) {
        let unread = urls.filter { u in libIndex[u].map { !library[$0].metadataRead } ?? false }
        guard !unread.isEmpty else { return }
        applyMetadata(unread.map { ($0, PhotoMetadata.read($0)) }, reselect: false)
    }

    func setRating(_ r: Int, on urls: [URL]? = nil) {
        let ts = urls ?? metadataTargets()
        guard !ts.isEmpty, !sidecarConflict(ts) else { return }
        ensureRead(ts)
        var value = r
        if r < 0, ts.allSatisfy({ photo($0)?.rating == -1 }) { value = 0 }        // X again un-rejects
        let old = Dictionary(grouping: ts) { photo($0)?.rating ?? 0 }
        undo.record(value < 0 ? "Reject" : "Rating",
                    undo: { [weak self] in old.forEach { v, us in self?.applyRating(v, to: us) } },
                    redo: { [weak self] in self?.applyRating(value, to: ts) })
        applyRating(value, to: ts)
        let what = value < 0 ? "Rejected" : value == 0 ? "Rating cleared" : String(repeating: "★", count: value)
        notify(.rating, what + (ts.count > 1 ? " · \(ts.count) photos" : ""), icon: value < 0 ? "xmark.circle" : "star")
    }

    private func applyRating(_ value: Int, to ts: [URL]) {
        writeMeta(ts, [XMPChange(tag: "xmp:Rating", value: String(value))]) { $0.rating = value }
    }

    func setLabel(_ name: String?, on urls: [URL]? = nil) {
        let ts = urls ?? metadataTargets()
        guard !ts.isEmpty, !sidecarConflict(ts) else { return }
        ensureRead(ts)
        var value = name
        if let n = name, ts.allSatisfy({ photo($0)?.label == n }) { value = nil }   // same key again clears
        let old = Dictionary(grouping: ts) { photo($0)?.label ?? "" }
        undo.record("Label",
                    undo: { [weak self] in old.forEach { v, us in self?.applyLabel(v.isEmpty ? nil : v, to: us) } },
                    redo: { [weak self] in self?.applyLabel(value, to: ts) })
        applyLabel(value, to: ts)
        notify(.label, (value.map { "\($0) label" } ?? "Label cleared") + (ts.count > 1 ? " · \(ts.count) photos" : ""), icon: "tag")
    }

    private func applyLabel(_ value: String?, to ts: [URL]) {
        writeMeta(ts, [XMPChange(tag: "xmp:Label", value: value)]) { $0.label = value }
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: move to _Rejected (FastRawViewer ⇧⌘⌫)

    nonisolated static let rejectedFolderName = "_Rejected"

    /// Moves the photos with their sidecar (and this app's sidecar backup) into `_Rejected` in the folder each RAW
    /// is in, and takes them out of the list; the neighbour becomes current. ⌘Z moves them back.
    func moveToRejected(_ targets: [URL]? = nil, recordUndo: Bool = true) {
        if NSApp.keyWindow?.firstResponder is NSText { return }             // ⇧⌘⌫ while typing in a field
        let ts = (targets ?? metadataTargets()).filter { libIndex[$0] != nil }
        guard !ts.isEmpty else { return }
        flushSettings()
        SidecarWriter.shared.runSync {}                  // queued sidecar writes land before the files move
        status = "Moving \(ts.count) photo(s) to \(Self.rejectedFolderName)…"
        Model.io.async {
            let r = Model.moveFiles(ts) { $0.deletingLastPathComponent().appendingPathComponent(Model.rejectedFolderName, isDirectory: true) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.rejectedMoved(r, recordUndo: recordUndo) } }
        }
    }

    struct MoveResult: Sendable {
        var raws: [URL] = []                      // RAWs that moved (their old place)
        var files: [(from: URL, to: URL)] = []    // every file moved, sidecars included
        var failed: [String] = []
    }

    /// Moves each RAW and the files that travel with it into `dir(raw)`; never overwrites.
    nonisolated static func moveFiles(_ raws: [URL], into dir: (URL) -> URL) -> MoveResult {
        let fm = FileManager.default
        var r = MoveResult()
        for u in raws {
            let d = dir(u)
            do {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                let dest = d.appendingPathComponent(u.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { r.failed.append("\(u.lastPathComponent) is already there"); continue }
                try fm.moveItem(at: u, to: dest)
                r.raws.append(u); r.files.append((u, dest))
                // a.ARW + a.DNG share a.xmp: it goes with the first one
                for c in [XMPFile.url(for: u), XMPFile.backupURL(for: u)] where fm.fileExists(atPath: c.path) {
                    let cd = d.appendingPathComponent(c.lastPathComponent)
                    if !fm.fileExists(atPath: cd.path), (try? fm.moveItem(at: c, to: cd)) != nil { r.files.append((c, cd)) }
                }
            } catch { r.failed.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        return r
    }

    private func rejectedMoved(_ r: MoveResult, recordUndo: Bool) {
        let gone = Set(r.raws)
        let photos = library.filter { gone.contains($0.url) }
        let saved = states.filter { gone.contains($0.key) }
        removeFromLibrary(gone)
        status = r.failed.isEmpty ? "Moved \(r.raws.count) photo(s) to \(Self.rejectedFolderName)"
            : "Moved \(r.raws.count) to \(Self.rejectedFolderName); not moved: " + r.failed.joined(separator: "; ")
        notify(.moveRejected, r.failed.isEmpty ? "Moved \(r.raws.count) photo(s) to \(Self.rejectedFolderName) · ⌘Z moves back" : status,
               icon: r.failed.isEmpty ? "archivebox" : "exclamationmark.triangle")
        guard recordUndo, !r.raws.isEmpty else { return }
        let files = r.files, raws = r.raws
        undo.record("Move to \(Self.rejectedFolderName)", undo: { [weak self] in
            self?.moveBack(files, photos: photos, states: saved)
        }, redo: { [weak self] in
            self?.moveToRejected(raws, recordUndo: false)
        })
    }

    /// Undo of a move to _Rejected: the files go back (newest first), the photos come back into the list.
    private func moveBack(_ files: [(from: URL, to: URL)], photos: [Photo], states saved: [URL: PhotoState]) {
        Model.io.async {
            let fm = FileManager.default
            var failed: [String] = []
            for f in files.reversed() {
                if fm.fileExists(atPath: f.from.path) { failed.append(f.from.lastPathComponent); continue }
                do { try fm.moveItem(at: f.to, to: f.from) } catch { failed.append(f.from.lastPathComponent) }
            }
            for d in Set(files.map { $0.to.deletingLastPathComponent() }) {      // remove _Rejected if it is empty now
                if (try? fm.contentsOfDirectory(atPath: d.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
                    try? fm.removeItem(at: d)
                }
            }
            let back = Set(files.map(\.from)).filter { fm.fileExists(atPath: $0.path) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let ps = photos.filter { back.contains($0.url) && self.libIndex[$0.url] == nil }
                    self.library = Model.merge(self.library, ps.sorted { Model.pathOrder($0.url, $1.url) })
                    self.libIndex = Dictionary(uniqueKeysWithValues: self.library.enumerated().map { ($1.url, $0) })
                    for (u, st) in saved where back.contains(u) { self.states[u] = st }
                    self.recomputeView(selectFirst: false)
                    if let first = ps.first { self.select(first.url) }
                    self.status = failed.isEmpty ? "Moved \(ps.count) photo(s) back" : "Could not move back: " + failed.joined(separator: ", ")
                }
            }
        }
    }

    private func removeFromLibrary(_ gone: Set<URL>) {
        guard !gone.isEmpty else { return }
        library.removeAll { gone.contains($0.url) }
        libIndex = Dictionary(uniqueKeysWithValues: library.enumerated().map { ($1.url, $0) })
        for u in gone { states[u] = nil; frvCache[u] = nil }
        selection.subtract(gone)
        recomputeView()                                  // the current photo's neighbour takes its place
    }

    // MARK: mouse wheel

    private var scrollAccum: CGFloat = 0
    private var lastScrollStep = Date.distantPast
    private var swipeAccum: CGFloat = 0
    private var swipeStepped = false                    // this horizontal swipe has turned its photo already
    private var lastSwipeStep = Date.distantPast

    /// A new trackpad gesture began (fingers down): the next horizontal swipe may turn a photo again.
    func scrollGestureBegan() { swipeAccum = 0; swipeStepped = false }

    /// A swipe gesture (Magic Mouse, three fingers, or two with "swipe between pages"): one photo per swipe.
    func swipePhoto(_ deltaX: CGFloat) {
        guard !zoomed, deltaX != 0 else { return }
        step(deltaX > 0 ? 1 : -1)
    }

    /// Wheel / trackpad over the picture: pans when zoomed, otherwise steps through the photos.
    /// A drag on the unzoomed photo that is clearly sideways and long (or flicked) enough turns one photo.
    func dragSwipe(_ t: CGSize, predicted: CGSize) {
        let x = abs(predicted.width) > abs(t.width) ? predicted.width : t.width
        guard abs(x) >= 80, abs(t.width) >= 2 * abs(t.height) else { return }
        step(x < 0 ? 1 : -1)
    }

    func handleScroll(dx: CGFloat, dy: CGFloat, momentum: Bool = false) {
        // one flick = one step, not a dozen; a sideways swipe may come mostly as momentum (Sidecar), so it still counts
        if !zoomed && momentum && !(abs(dx) > abs(dy) && !swipeStepped) { return }
        if zoomed {
            guard !unzooming else { return }      // a two-finger double-tap also sends empty scroll events
            zoomState.offset = clampedPan(CGSize(width: panOffset.width + dx, height: panOffset.height + dy))
            return
        }
        // A sideways two-finger swipe turns one photo per gesture, like paging (fingers to the left: next).
        // Devices without gesture phases (a tilting mouse wheel) may turn again after a pause.
        if abs(dx) > abs(dy) {
            if swipeStepped, Date().timeIntervalSince(lastSwipeStep) < 0.6 { return }
            swipeAccum += dx
            guard abs(swipeAccum) >= 24 else { return }
            step(swipeAccum < 0 ? 1 : -1)
            swipeAccum = 0; swipeStepped = true; lastSwipeStep = Date()
            return
        }
        scrollAccum += dy
        guard abs(scrollAccum) >= 8, Date().timeIntervalSince(lastScrollStep) > 0.18 else { return }
        step(scrollAccum < 0 ? 1 : -1)
        scrollAccum = 0
        lastScrollStep = Date()
    }

    private var metaSeq = 0
    private var lastAppliedSeq: [URL: Int] = [:]

    /// Writes rating / label / panel edits. Each call gets a sequence number, so a result that arrives late
    /// can never overwrite what a newer call already put on screen.
    private func writeMeta(_ urls: [URL], _ changes: [XMPChange], update: @escaping (inout Photo) -> Void, then: (() -> Void)? = nil) {
        metaSeq += 1
        let seq = metaSeq
        let after = then
        SidecarWriter.shared.submit({ () -> ([URL], [String]) in
            var ok: [URL] = [], errors: [String] = []
            for u in urls {
                do { try XMPFile.write(changes, for: u); ok.append(u) }
                catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
            }
            return (ok, errors)
        }, completion: { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                let (ok, errors) = (try? result.get()) ?? ([], ["write failed"])
                for u in ok where (self.lastAppliedSeq[u] ?? 0) < seq {
                    self.lastAppliedSeq[u] = seq
                    if let i = self.libIndex[u] {
                        update(&self.library[i])
                    }
                }
                self.recomputeView()
                if let c = self.current, ok.contains(c) { self.loadXMPPanel() }
                if let e = errors.first { self.status = "XMP write failed — \(e)" + (errors.count > 1 ? " (+\(errors.count - 1) more)" : "") }
                else { self.status = "Updated \(ok.count) sidecar(s)" }
                after?()
            }
        })
    }

    // MARK: XMP panel

    /// Reads and parses the sidecar off the main thread, then fills the XMP panel if the photo is still current.
    func loadXMPPanel() {
        guard let c = current else { xmpText = nil; xmpFields = []; xmpIssues = []; xmpDevelopLine = nil; return }
        Model.io.async { [weak self] in
            guard Model.ioCurrent.get() == c else { return }
            let read = XMPFile.read(c)?.0
            let parsed = read.map { ($0, XMPEdit.simpleFields($0), XMPEdit.validate($0), Sidecar.parse($0, url: XMPFile.url(for: c))) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.current == c else { return }
                    self.showXMPPanel(parsed)
                }
            }
        }
    }

    private func showXMPPanel(_ parsed: (String, [(String, String)], [String], Sidecar)?) {
        if let parsed {
            let (text, fields, issues, sc) = parsed
            xmpText = text
            xmpFields = fields
            xmpIssues = issues
            if let d = sc.develop {
                xmpDevelopLine = "Saved develop settings: \(String(format: "%+.2f", d.ev)) EV\(d.temp.map { ", \(Int($0)) K" } ?? ", as-shot WB")\(d.look.map { ", look \($0)" } ?? "")"
            } else { xmpDevelopLine = nil }
            let d = XMPDraft(rating: sc.rating, label: sc.label ?? "",
                             exposure: XMPEdit.value(of: "libraw:Exposure", in: text) ?? "",
                             temperature: XMPEdit.value(of: "crs:Temperature", in: text) ?? "",
                             tint: XMPEdit.value(of: "crs:Tint", in: text) ?? "",
                             adobeExposure: XMPEdit.value(of: "crs:Exposure2012", in: text) ?? "")
            xmpDraft = d; xmpOriginal = d
        } else {
            xmpText = nil; xmpFields = []; xmpIssues = []; xmpDevelopLine = nil
            xmpDraft = XMPDraft(); xmpOriginal = XMPDraft()
        }
    }

    /// The edits queued in the panel, as tag changes with old → new values for review.
    var xmpPendingChanges: [(tag: String, old: String, new: String, change: XMPChange)] {
        var out: [(String, String, String, XMPChange)] = []
        func add(_ tag: String, _ old: String, _ new: String) {
            guard old != new else { return }
            out.append((tag, old.isEmpty ? "—" : old, new.isEmpty ? "(removed)" : new, XMPChange(tag: tag, value: new.isEmpty ? nil : new)))
        }
        add("xmp:Rating", String(xmpOriginal.rating), String(xmpDraft.rating))
        add("xmp:Label", xmpOriginal.label, xmpDraft.label)
        add("libraw:Exposure", xmpOriginal.exposure, xmpDraft.exposure)
        add("crs:Temperature", xmpOriginal.temperature, xmpDraft.temperature)
        add("crs:Tint", xmpOriginal.tint, xmpDraft.tint)
        add("crs:Exposure2012", xmpOriginal.adobeExposure, xmpDraft.adobeExposure)
        return out
    }

    func writeXMPDraft() {
        guard let c = current else { return }
        let changes = xmpPendingChanges.map(\.change)
        guard !changes.isEmpty else { return }
        let d = xmpDraft, o = xmpOriginal
        let inverse = xmpPendingChanges.map { p in XMPChange(tag: p.tag, value: p.old == "—" ? nil : p.old) }
        undo.record("XMP Edit",
                    undo: { [weak self] in self?.applyXMP(inverse, rating: o.rating, label: o.label, to: c) },
                    redo: { [weak self] in self?.applyXMP(changes, rating: d.rating, label: d.label, to: c) })
        applyXMP(changes, rating: d.rating, label: d.label, to: c)
    }

    private func applyXMP(_ changes: [XMPChange], rating: Int, label: String, to c: URL) {
        writeMeta([c], changes, update: { $0.rating = rating; $0.label = label.isEmpty ? nil : label }, then: { [weak self] in
            guard let self else { return }
            self.frvCache[c] = nil                       // libraw:Exposure may have changed: re-read the starting EV
            if self.states[c] == nil { self.refreshAll() }
        })
    }

    func revertXMPDraft() { xmpDraft = xmpOriginal }

    /// Copies what the sidecar says about exposure / WB into the app's own develop settings.
    func importXMPIntoSettings(includeWB: Bool) {
        guard let c = current, let sc = Sidecar.load(for: c) else { return }
        editCurrent {
            if let e = sc.exposure { $0.ev = e }
            if includeWB { if let t = sc.temperature { $0.temp = t }; if let ti = sc.tint { $0.tint = ti } }
        }
        status = "Imported \(includeWB ? "exposure and WB" : "exposure") from the sidecar"
        refreshAll()
    }

    /// Puts the app's current EV / WB into the draft (still needs "Write to XMP").
    func fillXMPDraftFromSettings() {
        if let u = current { ensureRead([u]) }
        let s = currentState
        xmpDraft.exposure = String(format: "%.6f", s.ev)
        xmpDraft.temperature = String(Int((s.temp ?? asShot?.temp ?? 0).rounded()))
        xmpDraft.tint = String(Int((s.tint ?? asShot?.tint ?? 0).rounded()))
    }

    // MARK: history

    private static let inputsKey = "recentInputs"
    private static let outputsKey = "recentOutputs"
    private static let lutFoldersKey = "recentLUTFolders"
    private static let lutFolderKey = "lutFolder"
    private static let lutInputsKey = "lutInputs"
    @Published var recentInputs: [URL] = Model.loadHistory(Model.inputsKey)
    @Published var recentOutputs: [URL] = Model.loadHistory(Model.outputsKey)

    private static func loadHistory(_ key: String) -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    private func remember(_ list: inout [URL], _ key: String, _ new: [URL]) {
        var l = new + list.filter { !new.contains($0) }
        l = Array(l.prefix(10))
        list = l
        UserDefaults.standard.set(l.map(\.path), forKey: key)
    }

    func clearHistory() {
        recentInputs = []; recentOutputs = []; recentLUTFolders = []
        UserDefaults.standard.removeObject(forKey: Self.inputsKey)
        UserDefaults.standard.removeObject(forKey: Self.outputsKey)
        UserDefaults.standard.removeObject(forKey: Self.lutFoldersKey)
    }

    func addFavorite() {
        guard let f = currentFolder else { return }
        var l = favorites.filter { $0 != f }
        l.insert(f, at: 0)
        favorites = l
        UserDefaults.standard.set(l.map(\.path), forKey: "favoriteFolders")
    }

    func removeFavorite(_ u: URL) {
        favorites.removeAll { $0 == u }
        UserDefaults.standard.set(favorites.map(\.path), forKey: "favoriteFolders")
    }

    func useOutput(_ url: URL) {
        customOut = url
        if !outputMode.needsFolder { outputMode = .custom }
        remember(&recentOutputs, Self.outputsKey, [url])
    }

    func chooseOutput() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { useOutput(u) }
    }

    // MARK: LUTs

    /// Which input space each LUT expects is a property of the LUT, and a .cube cannot say it: it is kept in a small
    /// file in the LUT folder (path inside the folder → input name), so it goes wherever the folder is copied.
    nonisolated static let lutInputsFileName = "kestrel-lut-inputs.json"

    nonisolated static func readLUTInputs(_ folder: URL) -> [String: String] {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent(lutInputsFileName)),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return m
    }

    @discardableResult
    nonisolated static func writeLUTInputs(_ m: [String: String], to folder: URL) -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? d.write(to: folder.appendingPathComponent(lutInputsFileName), options: .atomic)) != nil
    }

    /// Older versions (and read-only LUT folders): this Mac's settings, by full path.
    private var savedLUTInputs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.lutInputsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.lutInputsKey) }
    }

    func chooseLUTFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.message = "Choose a folder containing .cube LUTs"
        if p.runModal() == .OK, let u = p.url { loadLUTFolder(u, remember: true) }
    }

    /// Where a LUT's input space comes from: its file name ("…_VLog"), a setting made by hand, or neither (assumed).
    enum LUTInputSource { case fileName, manual, assumed }

    struct LUTScan {
        var looks: [PPLook] = []; var urls: [Int: URL] = [:]; var skipped: [String] = []
        var sources: [Int: LUTInputSource] = [:]
    }

    /// Walks the folder and parses every .cube (about 1 s for 27 LUTs — never on the main thread).
    nonisolated static func scanLUTs(_ folder: URL, savedInputs: [String: String]) -> LUTScan {
        var urls: [URL] = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let f = walker?.nextObject() as? URL {
            if f.pathExtension.lowercased() == "cube" { urls.append(f) }
        }
        func group(_ u: URL) -> String {
            let parent = u.deletingLastPathComponent()
            return parent == folder ? "" : parent.lastPathComponent
        }
        urls.sort {
            let a = (group($0), $0.lastPathComponent), b = (group($1), $1.lastPathComponent)
            return a.0 == b.0 ? a.1.localizedStandardCompare(b.1) == .orderedAscending : a.0.localizedStandardCompare(b.0) == .orderedAscending
        }
        var r = LUTScan()
        var inFolder = readLUTInputs(folder)
        let before = inFolder
        func rel(_ u: URL) -> String { u.path.hasPrefix(folder.path + "/") ? String(u.path.dropFirst(folder.path.count + 1)) : u.lastPathComponent }
        for u in urls {
            do {
                let lut = try CubeLUT.load(u)
                if inFolder[rel(u)] == nil, let old = savedInputs[u.path] { inFolder[rel(u)] = old }    // move this Mac's setting over
                let guess = Scenes.guessInput(fromFileName: u.lastPathComponent)
                if let g = guess, inFolder[rel(u)] == g.name { inFolder[rel(u)] = nil }   // says what the name says: not kept
                let manual = inFolder[rel(u)].flatMap { n in Scenes.lutInputs.first { $0.name == n } }
                let input = manual ?? guess ?? Scenes.slog3SG3Cine
                let look = Looks.lutLook(index: r.looks.count, url: u, lut: lut, input: input, group: group(u))
                r.looks.append(look); r.urls[look.id] = u
                r.sources[look.id] = manual != nil ? .manual : guess != nil ? .fileName : .assumed
            } catch { r.skipped.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        if inFolder != before { writeLUTInputs(inFolder, to: folder) }
        return r
    }

    private var lutLoadSeq = 0

    func loadLUTFolder(_ folder: URL, remember doRemember: Bool) {
        lutLoadSeq += 1
        let seq = lutLoadSeq
        let saved = savedLUTInputs
        status = "Loading LUTs from \(folder.lastPathComponent)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let scan = Model.scanLUTs(folder, savedInputs: saved)
            await MainActor.run { [weak self] in
                guard let self, self.lutLoadSeq == seq else { return }      // a newer folder was chosen meanwhile
                self.applyLUTScan(scan, folder: folder, remember: doRemember)
            }
        }
    }

    private func applyLUTScan(_ scan: LUTScan, folder: URL, remember doRemember: Bool) {
        let keepKey = lookKey(ppID)
        // same folder again (reloaded, or a .cube dropped in): name the LUTs that were not there before
        let before = lutFolder == folder ? Set(lutURLs.values.map(\.path)) : nil
        let added = before.map { b in scan.urls.values.filter { !b.contains($0.path) }.map { $0.deletingPathExtension().lastPathComponent }.sorted() } ?? []
        luts = scan.looks
        lutURLs = scan.urls
        lutInputSources = scan.sources
        lutFolder = folder
        looksChanged()
        UserDefaults.standard.set(folder.path, forKey: Self.lutFolderKey)
        if doRemember { remember(&recentLUTFolders, Self.lutFoldersKey, [folder]) }
        if let k = keepKey, let id = lookID(forKey: k) { ppID = id } else if !looks.contains(where: { $0.id == ppID }) { ppID = 2 }
        batchPPs = batchPPs.filter { id in looks.contains { $0.id == id } }
        status = "\(scan.looks.count) LUT(s) in \(folder.lastPathComponent)" + (scan.skipped.isEmpty ? "" : " — skipped \(scan.skipped.count): \(scan.skipped[0])")
        if !added.isEmpty {
            notify(.lutsLoaded, added.count == 1 ? "New LUT: \(added[0])" : "\(added.count) new LUTs: " + added.prefix(3).joined(separator: ", ") + (added.count > 3 ? "…" : ""),
                   icon: "plus.circle.fill")
        } else if before == nil {
            notify(.lutsLoaded, "\(scan.looks.count) LUTs loaded from \(folder.lastPathComponent)" + (scan.skipped.isEmpty ? "" : " · \(scan.skipped.count) skipped"),
                   icon: "square.grid.3x3")
        } else if !scan.skipped.isEmpty {
            notify(.lutsLoaded, "\(scan.skipped.count) LUT file(s) could not be read", icon: "exclamationmark.triangle")
        }
        if current != nil { refreshAll() }
    }

    /// Look ids are list positions: cached previews / thumbnails keyed by them are no longer valid.
    private func looksChanged() {
        looksVersion += 1
        previewCache.removeAll()
        thumbCache.removeAll()
    }

    func clearLUTs() {
        luts = []; lutURLs = [:]; lutFolder = nil
        looksChanged()
        UserDefaults.standard.removeObject(forKey: Self.lutFolderKey)
        if ppID >= 100 { ppID = 2 }
        batchPPs = batchPPs.filter { $0 < 100 }
    }

    var currentLUTInput: SceneSpace? {
        if case .lut(_, let s) = look.kind { return s }
        return nil
    }

    private(set) var lutInputSources: [Int: LUTInputSource] = [:]

    /// A LUT look's input space, where it comes from, and what its file name alone would say.
    func lutInput(_ id: Int) -> (space: SceneSpace, source: LUTInputSource, guess: SceneSpace?)? {
        guard case .lut(_, let s) = look(id).kind, let url = lutURLs[id] else { return nil }
        return (s, lutInputSources[id] ?? .assumed, Scenes.guessInput(fromFileName: url.lastPathComponent))
    }

    /// Sets the input space of LUT `id` (the current look by default) by hand. The same as the file name says is
    /// not a setting: it is removed from kestrel-lut-inputs.json, which keeps only real overrides.
    func setLUTInput(_ space: SceneSpace, for lookID: Int? = nil) {
        let id = lookID ?? ppID
        guard let url = lutURLs[id], let f = lutFolder else { return }
        let guess = Scenes.guessInput(fromFileName: url.lastPathComponent)
        let byName = guess?.name == space.name
        notify(.lutInput, "\(url.deletingPathExtension().lastPathComponent) expects \(space.name)" + (byName ? " (from file name)" : " (manual)"),
               icon: "camera.filters")
        var m = Self.readLUTInputs(f); m[relativePath(url)] = byName ? nil : space.name
        var s = savedLUTInputs
        if Self.writeLUTInputs(m, to: f) { s[url.path] = nil }
        else if byName { s[url.path] = nil }
        else { s[url.path] = space.name; status = "LUT folder is read-only: \(space.name) is kept on this Mac only" }
        savedLUTInputs = s
        loadLUTFolder(f, remember: false)
    }

    /// Drops the hand-made input of LUT `id`: back to what its file name says (or the assumed default).
    func useFileNameInput(for lookID: Int? = nil) {
        let id = lookID ?? ppID
        guard let url = lutURLs[id], let f = lutFolder else { return }
        var m = Self.readLUTInputs(f); m[relativePath(url)] = nil
        Self.writeLUTInputs(m, to: f)
        var s = savedLUTInputs; s[url.path] = nil; savedLUTInputs = s
        let g = Scenes.guessInput(fromFileName: url.lastPathComponent)
        notify(.lutInput, "\(url.deletingPathExtension().lastPathComponent): input from the file name" + (g.map { " (\($0.name))" } ?? ""), icon: "camera.filters")
        loadLUTFolder(f, remember: false)
    }

    // MARK: selecting a photo and rendering

    func select(_ url: URL?) {
        flushSettings()
        RenderScheduler.shared.bumpPhoto()                 // everything queued for the old photo is skipped at dequeue
        watchdogTask?.cancel()
        current = url
        Model.ioCurrent.set(url)
        thumbs = [:]
        preview = nil
        previewIsPlaceholder = false
        overlay = nil
        previewError = nil
        previewRetries = 0
        renderedKey = nil
        asShot = nil
        xmpText = nil
        hist = nil
        pickingWB = false
        zoomImage = nil; zoomImageScale = 0                // never keep the previous photo's zoom on screen
        RenderScheduler.shared.setOnScreen(url)
        guard let url else { exifLines = []; imageSize = ""; RenderScheduler.shared.setNeighbours([]); return }
        if let f = currentFolder { UserDefaults.standard.set(url.lastPathComponent, forKey: "last:" + f.path) }
        if let e = exifCache[url] { exifLines = e.lines; imageSize = e.size } else { exifLines = []; imageSize = "" }
        let waiting = readMetadataSoon(url)                // rating, label and saved look before the real render
        syncLookFromState()
        loadXMPPanel()
        if viewMode == .single {
            showPlaceholder(url)
            if !waiting { refreshAll() }
        }
    }

    /// Something is on screen within milliseconds: the filmstrip thumbnail if we have it, then the camera's
    /// embedded JPEG (~12 ms to read). The real render replaces it; a late placeholder never overwrites a render.
    private func showPlaceholder(_ url: URL) {
        if preview == nil, let t = filmThumbs.images[url] { preview = t; previewIsPlaceholder = true }
        RenderScheduler.shared.placeholder { [weak self] in
            let img = EmbeddedPreview.load(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let img, self.current == url, self.preview == nil || self.previewIsPlaceholder else { return }
                    self.preview = img
                    self.previewIsPlaceholder = true
                }
            }
        }
    }

    /// After any change of photo or adjustment: the picture first, then histogram, thumbnails, EXIF, neighbours.
    func refreshAll() {
        let gens = RenderScheduler.shared.bumpPhoto()
        guard let url = current else { return }
        startPreview(url, gen: gens.preview)
        startAux(url, gen: gens.photo)
        if zoomed { refreshZoom(force: true) }
    }

    /// Only the big picture changed (look, overlay toggle): histogram and thumbnails stay valid.
    func refreshPreview(transient: Bool = false) {
        guard let url = current else { return }
        startPreview(url, gen: RenderScheduler.shared.bumpPreview(), transient: transient)
    }

    private func photoKey(_ url: URL) -> PhotoKey { PhotoKey(url: url, adj: state(for: url).adjust) }

    private func previewKey(_ url: URL, lookID: Int? = nil) -> PreviewKey {
        PreviewKey(photo: photoKey(url), lookID: lookID ?? ppID, looksVersion: looksVersion, over: showOver, under: showUnder)
    }

    private var currentPhotoKey: PhotoKey? { current.map(photoKey) }
    private var currentPreviewKey: PreviewKey? { current.map { previewKey($0) } }

    /// `transient` (slider drag frames): neither cached nor evicting the neighbours' bakes.
    private func baked(_ key: PhotoKey, transient: Bool = false) -> BakedPhoto {
        if let b = bakeCache[key] { return b }
        let b = BakedPhoto(key: key)
        if !transient { bakeCache[key] = b }
        return b
    }

    private func post(_ body: @escaping () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    private func showPreview(_ r: PreviewResult, for key: PreviewKey) {
        preview = r.image
        previewIsPlaceholder = false
        previewError = nil
        overlay = r.overlay
        renderedKey = key
        watchdogTask?.cancel()
    }

    private func startPreview(_ url: URL, gen: Int, transient: Bool = false) {
        let key = previewKey(url)
        if let r = previewCache[key] { showPreview(r, for: key); return }     // been here before: instant
        let look = self.look
        let b = baked(key.photo, transient: transient)
        RenderScheduler.shared.preview(gen: gen) { [weak self] in
            guard let cg = b.render(look) else {
                self?.post { [weak self] in
                    guard let self, self.currentPreviewKey == key else { return }
                    self.previewError = "Cannot decode \(url.lastPathComponent)"
                    self.preview = nil; self.previewIsPlaceholder = false
                    self.markUnreadable(url)
                }
                return
            }
            let img = NSImage(cgImage: cg, size: .zero)
            let ov = (key.over || key.under) ? b.makeOverlay(over: key.over, under: key.under) : nil
            let wb = b.asShot
            self?.post { [weak self] in
                guard let self else { return }
                let r = PreviewResult(image: img, overlay: ov)
                if !transient { self.previewCache[key] = r }
                if self.current == url, let wb { self.asShot = wb }
                guard self.currentPreviewKey == key else { return }           // a late result must not paint another photo
                self.showPreview(r, for: key)
            }
        }
        if !transient { armWatchdog(for: key) }
    }

    /// If the render for the current picture has not landed after a while (a lost job, a stalled GPU), ask again;
    /// after two retries say so instead of spinning forever.
    private func armWatchdog(for key: PreviewKey) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, self.currentPreviewKey == key, self.renderedKey != key, self.previewError == nil else { return }
            if self.previewRetries < 2 {
                self.previewRetries += 1
                self.previewCache[key] = nil
                self.refreshPreview()
            } else {
                self.previewError = "The preview of \(key.photo.url.lastPathComponent) did not arrive — press → then ← to retry"
                self.preview = nil; self.previewIsPlaceholder = false
            }
        }
    }

    private func markUnreadable(_ url: URL) {
        if let i = libIndex[url] { library[i].unreadable = true; recomputeViewKeepingCurrent() }
    }

    private func recomputeViewKeepingCurrent() {
        let c = current
        let ctx = filterContext
        shownPhotos = filter.ordered(library.filter { filter.matches($0, ctx) })
        counts = FilterCounts(library, shown: Set(shownPhotos.map(\.url)), ctx)
        current = c
    }

    /// Histogram, EXIF, the look thumbnails, then prefetch of the neighbours — all behind the preview.
    private func startAux(_ url: URL, gen: Int) {
        let pk = photoKey(url)
        let b = baked(pk)
        let s = RenderScheduler.shared

        if let h = histCache[pk] { hist = h } else {
            s.aux(photoGen: gen) { [weak self] in
                let h = b.makeHistogram()
                self?.post { [weak self] in
                    guard let self else { return }
                    if let h { self.histCache[pk] = h }
                    if self.currentPhotoKey == pk { self.hist = h }
                }
            }
        }

        if exifCache[url] == nil || asShot == nil {
            s.aux(photoGen: gen) { [weak self] in
                let exif = ExifInfo.read(url)
                let wb = b.asShot ?? RAWSource.for(url).asShot
                self?.post { [weak self] in
                    guard let self else { return }
                    self.exifCache[url] = exif
                    guard self.current == url else { return }
                    self.exifLines = exif.lines; self.imageSize = exif.size
                    if let wb, self.asShot == nil { self.asShot = wb }
                }
            }
        }

        let tk = ThumbKey(photo: pk, looksVersion: looksVersion)
        if let t = thumbCache[tk] { thumbs = t } else {
            let order = thumbOrder()
            s.aux(photoGen: gen) { [weak self] in
                guard let self else { return }
                var all: [Int: NSImage] = [:], batch: [Int: NSImage] = [:]
                for (i, look) in order.enumerated() {
                    if s.photoGen != gen { return }
                    s.yieldToPreview()
                    if let cg = b.render(look, thumbnail: true) {
                        let img = NSImage(cgImage: cg, size: .zero)
                        all[look.id] = img; batch[look.id] = img
                    }
                    if i == min(11, order.count - 1) || i == order.count - 1 {   // first screenful, then the rest
                        let chunk = batch; batch = [:]
                        self.post { [weak self] in
                            guard let self, self.currentPhotoKey == pk else { return }
                            self.thumbs.merge(chunk) { _, new in new }
                        }
                    }
                }
                self.post { [weak self] in self?.thumbCache[tk] = all }
            }
        }

        prefetchNeighbours(of: url)
    }

    /// Favourites (the top of the LUT panel) first, then the rest.
    private func thumbOrder() -> [PPLook] {
        let shown = visibleLooks
        let ids = Set(shown.map(\.id))
        return shown + looks.filter { !ids.contains($0.id) }
    }

    /// Renders the previous and next photo (preview, histogram, thumbnails) into the caches while the GPU is idle,
    /// so a step in either direction is instant. Stops as soon as a photo is no longer a neighbour.
    private func prefetchNeighbours(of url: URL) {
        let s = RenderScheduler.shared
        guard let i = fileIndex[url] else { s.setNeighbours([]); return }
        let candidates = [i + 1, i - 1].filter { files.indices.contains($0) }.map { files[$0] }
            .filter { photo($0)?.metadataRead != false }           // unread: its saved look isn't known, the render would be wasted
        s.setNeighbours(Set(candidates))
        let look = self.look
        let order = thumbOrder()
        for n in candidates {
            let key = previewKey(n)
            let tk = ThumbKey(photo: key.photo, looksVersion: looksVersion)
            if previewCache.contains(key) && histCache.contains(key.photo) && thumbCache.contains(tk) { continue }
            let b = baked(key.photo)
            s.aux(stillWanted: { s.isNeighbour(n) }) { [weak self] in
                guard let self else { return }
                if !self.previewCache.contains(key), let cg = b.render(look) {
                    let r = PreviewResult(image: NSImage(cgImage: cg, size: .zero),
                                          overlay: (key.over || key.under) ? b.makeOverlay(over: key.over, under: key.under) : nil)
                    self.previewCache[key] = r
                    // Already stepped onto it while we rendered? Then this *is* the current picture.
                    self.post { [weak self] in
                        guard let self, self.currentPreviewKey == key, self.renderedKey != key else { return }
                        self.showPreview(r, for: key)
                    }
                }
                s.yieldToPreview()
                guard s.isNeighbour(n) else { return }
                if !self.histCache.contains(key.photo), let h = b.makeHistogram() {
                    self.histCache[key.photo] = h
                    self.post { [weak self] in
                        guard let self, self.currentPhotoKey == key.photo, self.hist == nil else { return }
                        self.hist = h
                    }
                }
                guard !self.thumbCache.contains(tk) else { return }
                var all: [Int: NSImage] = [:]
                for look in order {
                    s.yieldToPreview()
                    guard s.isNeighbour(n) else { return }
                    if let cg = b.render(look, thumbnail: true) { all[look.id] = NSImage(cgImage: cg, size: .zero) }
                }
                self.thumbCache[tk] = all
                self.post { [weak self] in
                    guard let self, self.currentPhotoKey == key.photo, self.thumbs.count < all.count else { return }
                    self.thumbs = all
                }
            }
        }
    }

    // MARK: overlays

    func toggleOver() {
        showOver.toggle(); refreshPreview()
        notify(.overlay, "Over-exposure overlay " + (showOver ? "on" : "off"), icon: "sun.max.trianglebadge.exclamationmark")
    }
    func toggleUnder() {
        showUnder.toggle(); refreshPreview()
        notify(.overlay, "Under-exposure overlay " + (showUnder ? "on" : "off"), icon: "moon")
    }

    // MARK: zoom and pan (100 % = one image pixel per screen pixel)

    private var backing: Double { Double(mainWindow?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    /// Fit-to-window magnification, as a fraction of 100 %.
    var fitScale: Double {
        let px = imagePixels, b = backing
        guard px.width > 0, px.height > 0 else { return 0.25 }
        // less the fitted picture's 6 pt padding, so zooming starts and ends exactly on the fitted picture
        return min((viewSize.width - 12) / (px.width / b), (viewSize.height - 12) / (px.height / b))
    }

    /// The "just right" zoom for a double-click / Z: the smallest standard step (25, 33, 50, 67, 100 %) that is at
    /// least `smartZoomFactor` × the fit size, never above 100 %. It roughly doubles what you see instead of leaping
    /// to a 1:1 crop; on a big screen where fit is already ≥ 50 % it is simply 100 %.
    var smartZoomScale: Double {
        guard smartZoomFactor > 0 else { return 1 }
        let target = fitScale * smartZoomFactor
        return Model.zoomSteps.first { $0 >= target - 1e-6 } ?? 1.0
    }

    var zoomLabel: String { zoomed ? "\(Int((zoomScale * 100).rounded())) %" : "Fit" }

    func unzoom() {
        zoomed = false; zoomImage = nil; zoomImageScale = 0; unzooming = false
        pinchRender?.cancel(); unzoomGen += 1; RenderScheduler.shared.bumpZoom()
    }

    static let zoomAnimation = Animation.spring(response: 0.3, dampingFraction: 0.9)
    private var unzoomGen = 0
    private(set) var unzooming = false

    /// Shrinks the picture back to the fit size, then leaves zoom (instant when not zoomed).
    func unzoomAnimated() {
        guard zoomed, abs(zoomScale - fitScale) > 1e-6 else { return unzoom() }   // nothing to animate
        unzoomGen += 1
        let gen = unzoomGen
        unzooming = true
        // The animation itself runs in Core Animation (ZoomLayerView); SwiftUI's transaction only tells it to animate.
        // SwiftUI has nothing of its own to animate here, so its completion would not wait for the spring: swap to
        // the fitted view on the layer's own clock, as a cut (in the animated transaction it became a cross-fade).
        withAnimation(Model.zoomAnimation) { zoomState.scale = fitScale; zoomState.offset = .zero }
        DispatchQueue.main.asyncAfter(deadline: .now() + ZoomLayerView.unzoomDuration) { [weak self] in
            guard let self, self.unzoomGen == gen else { return }      // zoomed in again meanwhile
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { self.unzoom() }
        }
    }

    /// The picture's size in points at 100 %.
    var fullSizePt: CGSize { CGSize(width: imagePixels.width / backing, height: imagePixels.height / backing) }

    /// Zooms to `scale` (fraction of 100 %) with a short animation, keeping the spot under `point` (points from the
    /// view's top-left: the click or the fingers) where it is, otherwise keeping the current centre.
    func zoom(to scale: Double, atFit point: CGPoint? = nil) {
        guard current != nil, viewMode == .single else { return }
        let fit = fitScale
        if scale <= fit + 1e-6 { unzoomAnimated(); return }
        unzoomGen += 1; unzooming = false                          // cancels an unzoom still animating
        let wasZoomed = zoomed
        if !wasZoomed { zoomState.scale = fit; zoomState.offset = .zero; zoomed = true }
        let old = zoomScale, new = min(scale, Model.maxZoom), f = new / old
        let c = point.map { CGSize(width: $0.x - viewSize.width / 2, height: $0.y - viewSize.height / 2) } ?? .zero
        let target = clampedPan(CGSize(width: (panOffset.width - c.width) * f + c.width,
                                       height: (panOffset.height - c.height) * f + c.height), scale: new)
        let url = current
        let go = { [weak self] in
            guard let self, self.zoomed, self.current == url else { return }      // not if the photo changed meanwhile
            withAnimation(Model.zoomAnimation) { self.zoomState.scale = new; self.zoomState.offset = target }
            self.refreshZoom()
        }
        // a freshly shown zoomed picture has to appear at the fit size first, or there is nothing to animate from
        if wasZoomed { go() } else { DispatchQueue.main.async(execute: go) }
    }

    /// Trackpad pinch over the picture, anchored at `p` (points from the view's top-left): the picture follows the
    /// fingers continuously; a sharp render at the new scale follows when the pinch pauses or ends. Pinching back
    /// to the fit size (or below) returns to fit.
    func pinch(_ magnification: Double, at p: CGPoint, ended: Bool) {
        guard current != nil, viewMode == .single else { return }
        let fit = fitScale
        if ended {
            guard zoomed else { return }
            if zoomScale <= fit * 1.03 { unzoomAnimated() } else { objectWillChange.send(); refreshZoom() }   // status-bar %
            return
        }
        if !zoomed {
            guard magnification > 0 else { return }                // pinching in on the fitted picture: nothing to do
            zoomState.scale = fit; zoomState.offset = .zero
            zoomed = true
        }
        unzoomGen += 1; unzooming = false
        let old = zoomScale
        let new = min(max(old * (1 + magnification), fit), Model.maxZoom)
        let f = new / old
        let c = CGSize(width: p.x - viewSize.width / 2, height: p.y - viewSize.height / 2)   // fingers, from the centre
        zoomState.scale = new
        zoomState.offset = clampedPan(CGSize(width: (panOffset.width - c.width) * f + c.width,
                                             height: (panOffset.height - c.height) * f + c.height))
        // No sharp render until the fingers lift (or rest for a while): a full-size render mid-gesture makes it stutter.
        pinchRender?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshZoom() }
        pinchRender = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// Dragging the status-bar zoom indicator: right zooms in, left out, around the middle of the picture, like a pinch.
    func dragZoom(_ points: CGFloat, _ mods: NSEvent.ModifierFlags) {
        let k: CGFloat = mods.contains(.option) ? 0.0015 : mods.contains(.shift) ? 0.02 : 0.006
        pinch(Double(points * k), at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), ended: false)
    }

    func dragZoomEnded() { pinch(0, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), ended: true) }

    /// Double-click / Z / status-bar indicator: fit ↔ smart zoom.
    func toggleZoom(atFit point: CGPoint? = nil) {
        if zoomed { unzoomAnimated() } else { zoom(to: smartZoomScale, atFit: point) }
    }

    /// ⌘+ / ⌘−: next / previous standard zoom step (below the fit size means fit).
    func zoomStep(_ dir: Int) {
        let cur = zoomed ? zoomScale : fitScale
        if dir > 0 {
            if let n = Model.zoomSteps.first(where: { $0 > cur + 1e-6 }) { zoom(to: n) }
        } else if let n = Model.zoomSteps.last(where: { $0 < cur - 1e-6 }), n > fitScale + 1e-6 {
            zoom(to: n)
        } else { unzoomAnimated() }
    }

    private var imagePixels: CGSize {
        let parts = imageSize.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return CGSize(width: 6000, height: 4000) }
        // EXIF size is un-rotated; the preview tells us the orientation.
        if let p = preview, (p.size.width > p.size.height) != (parts[0] > parts[1]) { return CGSize(width: parts[1], height: parts[0]) }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// The render scale for a zoom: the next standard step up (so small zoom changes reuse the render), never above
    /// 100 % (beyond that the 100 % render is enlarged).
    private func renderScale(for zoom: Double) -> Float {
        Float(Model.zoomSteps.first { $0 >= zoom - 1e-6 } ?? 1)
    }

    /// Renders the picture for the current zoom unless that render is already on screen.
    func refreshZoom(force: Bool = false) {
        guard zoomed, let url = current else { return }
        let renderScale = renderScale(for: zoomScale)
        if !force, zoomImage != nil, zoomImageScale == Double(renderScale) { return }
        let d = Decoded(url: url, adj: state(for: url).adjust, scale: renderScale)
        let look = self.look
        let scale = backing
        let gen = RenderScheduler.shared.bumpZoom()
        RenderScheduler.shared.zoom(gen: gen) { [weak self] in
            guard let ci = d.render(look), let cg = Engine.cgImage(ci, look) else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) / scale, height: Double(cg.height) / scale))
            self?.post { [weak self] in
                guard let self, self.current == url, self.zoomed, self.renderScale(for: self.zoomScale) == d.scale else { return }
                self.zoomImage = img
                self.zoomImageScale = Double(d.scale)
            }
        }
    }

    func dragPan(_ t: CGSize) {
        if !dragging { dragging = true; panStart = panOffset }
        zoomState.offset = clampedPan(CGSize(width: panStart.width + t.width, height: panStart.height + t.height))
    }

    func endPan() { dragging = false }

    /// Keeps the picture's edges from coming inside the view (a picture smaller than the view stays centred).
    func clampedPan(_ o: CGSize, scale: Double? = nil) -> CGSize {
        let k = scale ?? zoomScale
        let z = CGSize(width: fullSizePt.width * k, height: fullSizePt.height * k)
        let mx = max(0, (z.width - viewSize.width) / 2), my = max(0, (z.height - viewSize.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    // MARK: white balance picking

    func pickWhite(atFit point: CGPoint) {
        guard let url = current, let img = preview else { return }
        let vw = viewSize.width, vh = viewSize.height
        let s = min(vw / img.size.width, vh / img.size.height)
        let w = img.size.width * s, h = img.size.height * s
        let u = (point.x - (vw - w) / 2) / w, v = (point.y - (vh - h) / 2) / h
        guard (0...1).contains(u), (0...1).contains(v) else { return }
        pickingWB = false
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = Decoded.pickNeutral(url, u: u, vFromTop: v)
            await MainActor.run {
                guard let self, self.current == url, let r else { return }
                self.editCurrent { $0.temp = r.temp; $0.tint = r.tint }
                self.status = String(format: "WB picked: %.0f K / %+.0f", r.temp, r.tint)
                self.refreshAll()
            }
        }
    }

    // MARK: auto exposure

    func autoExposure(scope: [URL]) {
        guard !scope.isEmpty, !exporting else { return }
        let mode = meteringMode
        status = "Metering \(scope.count) photo(s)…"
        let g = UUID().uuidString                                   // the whole run is one undo step
        Task.detached(priority: .userInitiated) { [weak self] in
            var done = 0, circles = 0
            var lastEV: Float?
            for url in scope {
                guard let r = Metering.autoEVResult(url: url, baseEV: 0, mode: mode) else { continue }
                done += 1
                lastEV = r.ev
                if r.circleMasked { circles += 1 }
                await MainActor.run { self?.edit([url], group: g) { $0.ev = r.ev } }
            }
            let single = scope.count == 1 ? lastEV : nil
            await MainActor.run {
                self?.status = "Auto EV (\(mode.rawValue)) set for \(done) photo(s)."
                    + (circles > 0 ? " Lens corners ignored on \(circles)." : "")
                let what = single.map { String(format: "Auto exposure %+.1f EV", $0) } ?? "Auto exposure set for \(done) photo(s)"
                self?.notify(.autoExposure, what + " · \(mode.title)" + (circles > 0 ? " · lens corners ignored" : ""), icon: "plusminus.circle")
                self?.refreshAll()
            }
        }
    }

    // MARK: export

    /// What a batch exports: the selection if there is one, otherwise the filtered list; never rejected photos.
    var exportTargets: [URL] {
        if let c = exportTargetsCache { return c }
        let base = selection.isEmpty ? shownPhotos : shownPhotos.filter { selection.contains($0.url) }
        let t = base.filter { !$0.isRejected }.map(\.url)
        exportTargetsCache = t
        return t
    }

    var exportScopeText: String { selection.isEmpty ? "shown" : "selected" }

    func cancelExport() { exportTask?.cancel() }

    /// Exports only the current photo with the current look, to a location chosen in a save panel.
    func exportCurrent() {
        guard let url = current, !exporting else { return }
        ensureRead([url])                                          // its saved settings, even if still being read
        let look = self.look
        let stem = url.deletingPathExtension().lastPathComponent
        let p = NSSavePanel()
        p.allowedContentTypes = [.heic]
        p.nameFieldStringValue = "\(stem)_\(look.fileName).heic"
        p.directoryURL = customOut ?? url.deletingLastPathComponent()
        guard p.runModal() == .OK, let dest = p.url else { return }
        export(url, look: look, to: dest)
    }

    /// One click: the photo on screen with its look, into the folder the Export settings name, no dialog.
    func quickExport() {
        guard let url = current, !exporting else { return }
        ensureRead([url])
        let look = self.look
        let dir = outputMode.directory(for: url, custom: customOut, look: look, group: groupByLook)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { status = "Can't write to \(dir.path): \(error.localizedDescription)"; return }
        export(url, look: look, to: dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_\(look.fileName).heic"))
    }

    /// The photo on screen, rendered full size with its look, on the clipboard (to paste into a message or document).
    func copyImageToClipboard() {
        guard let url = current else { return }
        ensureRead([url])
        let look = self.look
        let dec = Decoded(url: url, adj: state(for: url).adjust, scale: 1)
        let name = url.deletingPathExtension().lastPathComponent
        status = "Rendering \(name) for the clipboard…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let cg = dec.render(look).flatMap { Engine.cgImage($0, look) }
            await MainActor.run {
                guard let self else { return }
                guard let cg else {
                    self.status = "Could not render \(name)"
                    self.notify(.copyPhoto, self.status, icon: "exclamationmark.triangle")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
                self.status = "Copied the edited \(name) · \(look.title) (\(cg.width) × \(cg.height)) to the clipboard"
                self.notify(.copyPhoto, "Edited photo copied · \(look.title) · \(cg.width) × \(cg.height)", icon: "doc.on.doc")
            }
        }
    }

    private func export(_ url: URL, look: PPLook, to dest: URL) {
        let stem = url.deletingPathExtension().lastPathComponent
        exporting = true
        progress = 0
        status = "Exporting \(stem) · \(look.title)…"
        let dec = Decoded(url: url, adj: state(for: url).adjust, scale: 1)
        let q = Float(quality)
        let sc = copySidecar ? Sidecar.load(for: url) : nil
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            var msg: String
            do {
                guard let img = dec.render(look) else { throw CocoaError(.fileReadCorruptFile) }
                try Engine.heic10(img, look, quality: q).write(to: dest)
                if let sc {
                    let x = dest.deletingPathExtension().appendingPathExtension("xmp")
                    try? FileManager.default.removeItem(at: x)
                    try? FileManager.default.copyItem(at: sc.url, to: x)
                }
                msg = "Saved \(dest.lastPathComponent)"
            } catch { msg = "Failed: \(error.localizedDescription)" }
            let ok = msg.hasPrefix("Saved")
            await MainActor.run {
                self?.exporting = false; self?.status = msg
                self?.notify(.export, ok ? "Exported \(dest.lastPathComponent) → \(dest.deletingLastPathComponent().lastPathComponent)/" : msg,
                             icon: ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
            }
        }
    }

    func exportAll() {
        ensureRead(selection.isEmpty ? files : files.filter(selection.contains))   // so unread rejects stay out
        let jobs = exportTargets
        let looks = self.looks.filter { batchPPs.contains($0.id) }
        guard !jobs.isEmpty, !looks.isEmpty, !exporting else { return }
        if let problem = outputProblem(for: jobs) { status = problem; return }
        exporting = true
        progress = 0
        let total = Double(jobs.count * looks.count)
        let adjs = Dictionary(uniqueKeysWithValues: jobs.map { ($0, state(for: $0).adjust) })
        let copyXMP = copySidecar
        let q = Float(quality)
        let out = customOut
        let mode = outputMode
        let group = groupByLook
        // Up to 3 photos in flight: the HEVC encoder and the GPU overlap (2.5× over one at a time, ~400 MB each).
        let width = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 3))
        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            /// One photo, every ticked look. Returns (files written or failed, failure messages).
            @Sendable func exportPhoto(_ url: URL) -> (Int, [String]) {
                autoreleasepool {
                    let sc = copyXMP ? Sidecar.load(for: url) : nil
                    let dec = Decoded(url: url, adj: adjs[url] ?? Adjust(), scale: 1)    // lazy: one decode graph per look
                    let stem = url.deletingPathExtension().lastPathComponent
                    var n = 0, fails: [String] = []
                    for look in looks {
                        if Task.isCancelled { break }
                        let dir = mode.directory(for: url, custom: out, look: look, group: group)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let dest = dir.appendingPathComponent("\(stem)_\(look.fileName).heic")
                        do {
                            guard let img = dec.render(look) else { throw CocoaError(.fileReadCorruptFile) }
                            try Engine.heic10(img, look, quality: q).write(to: dest)
                            if let sc {
                                let x = dest.deletingPathExtension().appendingPathExtension("xmp")
                                try? FileManager.default.removeItem(at: x)
                                try? FileManager.default.copyItem(at: sc.url, to: x)
                            }
                        } catch { fails.append("\(stem) \(look.title): \(error.localizedDescription)") }
                        n += 1
                    }
                    return (n, fails)
                }
            }

            var done = 0, failures: [String] = []
            await withTaskGroup(of: (Int, [String]).self) { g in
                var next = 0
                func add() { if next < jobs.count, !Task.isCancelled { let u = jobs[next]; next += 1; g.addTask { exportPhoto(u) } } }
                for _ in 0..<width { add() }
                while let (n, fails) = await g.next() {
                    done += n; failures += fails
                    let p = Double(done) / total, d = done
                    await MainActor.run { self?.progress = p; self?.status = "Exporting… \(d) of \(Int(total))" }
                    add()
                }
            }
            let cancelled = Task.isCancelled
            await MainActor.run {
                guard let self else { return }
                self.exporting = false
                if cancelled { self.status = "Cancelled after \(done) file(s)." }
                else if failures.isEmpty { self.status = "Done — \(done) file(s) written." }
                else { self.status = "Finished with \(failures.count) failure(s): \(failures.first ?? "")" }
                self.notify(.batchExport, self.status, icon: failures.isEmpty && !cancelled ? "checkmark.circle.fill" : "exclamationmark.triangle")
            }
        }
    }

    /// Checks every destination folder can be created and written before a long batch starts.
    private func outputProblem(for jobs: [URL]) -> String? {
        let fm = FileManager.default
        let looks = self.looks.filter { batchPPs.contains($0.id) }
        var checked: Set<URL> = []
        for u in jobs {
            for l in looks {
                let d = outputMode.directory(for: u, custom: customOut, look: l, group: groupByLook)
                guard checked.insert(d).inserted else { continue }
                do { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
                catch { return "Cannot create \(d.path): \(error.localizedDescription)" }
                if !fm.isWritableFile(atPath: d.path) { return "Output folder is not writable: \(d.path)" }
            }
        }
        return nil
    }
}
