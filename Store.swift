import Foundation

// MARK: - Photos

let rawExtensions: Set<String> = ["arw", "raf", "cr2", "dng"]

struct Photo: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var rating = 0                  // -1 = rejected, 0...5
    var label: String?              // Red / Yellow / Green / Blue / Purple
    var date = Date.distantPast
    var unreadable = false
    /// False until the background reader has looked at the sidecar and EXIF (FastRawViewer-style delayed loading).
    var metadataRead = false
    var gear = ""                   // EXIF make, model and lens; the name filter searches it too
    var name: String { url.lastPathComponent }
    var kind: String { url.pathExtension.uppercased() }
    var isRejected: Bool { rating < 0 }
}

// MARK: - Delayed metadata loading

/// What the background reader finds for one photo: sidecar rating / label / saved develop settings and the capture date.
struct PhotoMetadata {
    var rating = 0
    var label: String?
    var develop: PhotoState?
    var date = Date.distantPast
    var gear = ""
    var exposure: Float?            // libraw:Exposure (FastRawViewer) or crs:Exposure2012, the starting EV

    static func read(_ url: URL) -> PhotoMetadata {
        var m = PhotoMetadata()
        if !ScanIndex.shared.knownWithoutSidecar(url), let sc = Sidecar.load(for: url) { m.rating = sc.rating; m.label = sc.label; m.develop = sc.develop; m.exposure = sc.exposure }
        let exif = ExifInfo.capture(url)
        m.gear = exif.gear
        m.date = exif.date ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return m
    }
}

/// Hands out the photos of a folder in batches, the ones around the current photo first. Thread-safe; one per folder.
final class MetadataReader {
    private var order: [URL]
    private var index: [URL: Int]
    private var remaining: Set<URL>
    private var front: [URL] = []
    private var cursor = 0
    private var cancelled = false
    private var open: Bool                       // the folder is still being scanned: more files may come
    private let cond = NSCondition()
    let batchSize: Int

    init(files: [URL], batchSize: Int = 32, open: Bool = false) {
        order = files
        index = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
        remaining = Set(files)
        self.batchSize = batchSize
        self.open = open
    }

    var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }
    func cancel() { cond.lock(); cancelled = true; cond.broadcast(); cond.unlock() }

    /// More files found by a scan still running.
    func add(_ urls: [URL]) {
        cond.lock(); defer { cond.unlock() }
        for u in urls where index[u] == nil { index[u] = order.count; order.append(u); remaining.insert(u) }
        cond.broadcast()
    }

    /// The scan is done: readers stop once everything is read.
    func close() { cond.lock(); open = false; cond.broadcast(); cond.unlock() }

    /// Read `url` and its neighbours next (the current photo moved).
    func prioritise(_ url: URL, radius: Int = 16) {
        cond.lock(); defer { cond.unlock() }
        guard let i = index[url] else { return }
        let lo = max(0, i - radius), hi = min(order.count - 1, i + radius)
        var ahead: [URL] = [url]
        for d in 1...max(1, radius) {                         // alternate forward / backward, nearest first
            if i + d <= hi { ahead.append(order[i + d]) }
            if i - d >= lo { ahead.append(order[i - d]) }
        }
        front = ahead.filter { remaining.contains($0) } + front
    }

    /// The next batch of unread files; waits while a scan may still add some. Nil when everything has been handed
    /// out (and the scan is done) or the reader was cancelled.
    func next() -> [URL]? {
        cond.lock(); defer { cond.unlock() }
        while !cancelled, remaining.isEmpty, open { cond.wait() }
        guard !cancelled, !remaining.isEmpty else { return nil }
        var batch: [URL] = []
        while batch.count < batchSize, !front.isEmpty {
            let u = front.removeFirst()
            if remaining.remove(u) != nil { batch.append(u) }
        }
        while batch.count < batchSize, cursor < order.count {
            let u = order[cursor]; cursor += 1
            if remaining.remove(u) != nil { batch.append(u) }
        }
        return batch.isEmpty ? nil : batch
    }
}

let labelNames = ["Red", "Yellow", "Green", "Blue", "Purple"]

// MARK: - Per-photo develop settings (saved into the .xmp sidecar, see DevelopXMP)

struct PhotoState: Codable, Equatable {
    var ev: Float = 0
    var temp: Float?                // Kelvin, nil = as shot
    var tint: Float?
    var hl = true                   // highlight recovery
    var look: String?               // "pp:7" or "lut:<path in the LUT folder>"; nil = keep the current look
    var contrast: Float = 0         // FastRawViewer contrast grade, -5...+5, in 0.1 steps (K / ⇧K move 0.5)

    var adjust: Adjust { Adjust(ev: ev, temp: temp, tint: tint, highlightRecovery: hl, contrast: contrast) }
}

// MARK: - Filtering and sorting (replaces FastRawViewer's Sort & Filter panel)

/// FastRawViewer's EXIF timestamp rows. Disjoint and exhaustive, so each read photo is in exactly one row.
enum DateBucket: Int, CaseIterable, Identifiable {
    case today, yesterday, lastWeek, lastMonth, thisYear, past, none
    var id: Int { rawValue }
    var title: String { ["Today", "Yesterday", "Last week", "Last month", "This year", "Past", "No timestamp"][rawValue] }
}

/// Cut points, computed once per folder load / refresh (FastRawViewer freezes its ranges too).
struct DateBuckets: Equatable {
    var t0: Date, yesterday: Date, week: Date, month: Date, year: Date
    init(now: Date = Date(), cal: Calendar = .current) {
        t0 = cal.startOfDay(for: now)
        yesterday = cal.date(byAdding: .day, value: -1, to: t0)!
        week = cal.date(byAdding: .day, value: -7, to: t0)!
        month = cal.date(byAdding: .day, value: -30, to: t0)!
        year = cal.date(from: cal.dateComponents([.year], from: now))!
    }
    func bucket(_ d: Date) -> DateBucket {
        if d == .distantPast { return .none }
        if d >= t0 { return .today }
        if d >= yesterday { return .yesterday }
        if d >= week { return .lastWeek }
        if d >= month { return .lastMonth }
        if d >= year { return .thisYear }
        return .past
    }
    /// The range a row covers, for its tooltip.
    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()

    func range(_ b: DateBucket) -> String {
        let f = Self.dayFormat
        let day: TimeInterval = 86400
        switch b {
        case .today: return f.string(from: t0) + " and later"
        case .yesterday: return f.string(from: yesterday)
        case .lastWeek: return f.string(from: week) + " – " + f.string(from: yesterday - day)
        case .lastMonth: return f.string(from: month) + " – " + f.string(from: week - day)
        case .thisYear: return year < month ? f.string(from: year) + " – " + f.string(from: month - day) : "empty this early in the year"
        case .past: return "before " + f.string(from: min(year, month))
        case .none: return "no EXIF date and no file date"
        }
    }
}

/// Whether the look saved for a photo is a .cube LUT (the photo's own setting, not the look on screen).
enum LookKind: Int, CaseIterable, Identifiable {
    case lut, noLUT
    var id: Int { rawValue }
    var title: String { self == .lut ? "With LUT" : "Without LUT" }
    static func of(_ key: String?) -> LookKind { key?.hasPrefix("lut:") == true ? .lut : .noLUT }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, kind, date, rating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Filename"
        case .kind: "File type"
        case .date: "EXIF timestamp"
        case .rating: "XMP rating"
        }
    }
}

/// Per-photo facts the filter needs that live outside `Photo`.
struct FilterContext {
    var buckets: DateBuckets
    var selection: Set<URL>
    var lookKey: (URL) -> String?
    /// The name / mask test, built once per recompute (an NSPredicate per photo is slow).
    var nameTest: ((String) -> Bool)? = nil
}

/// FastRawViewer's Sort & Filter: ticks are OR inside a group and AND across groups; an empty group is no condition.
struct FilterState: Equatable {
    var enabled = true
    var ratings: Set<Int> = []         // 0 = not set, -1 = rejected
    var labels: Set<String> = []       // "None" = not set
    var dates: Set<DateBucket> = []
    var looks: Set<LookKind> = []
    var kinds: Set<String> = []        // "ARW", "RAF", "CR2", "DNG"
    var selectedOnly = false
    var hideRejected = true
    var name = ""                      // substring or * mask on the file name, or on camera / lens; kept by V and Reset
    var sort: SortKey = .name
    var reverse = false

    /// Name, file type and Selected apply to every photo; the metadata groups only once a photo's metadata is read
    /// (until then it passes, so the view doesn't blank and refill while the reader works).
    func matches(_ p: Photo, _ c: FilterContext) -> Bool {
        if !name.isEmpty {
            let test = c.nameTest ?? nameTest
            if !test(p.name), !test(p.gear) { return false }                // gear: once metadata is read
        }
        guard enabled else { return true }
        if !kinds.isEmpty, !kinds.contains(p.kind) { return false }
        if selectedOnly, !c.selection.contains(p.url) { return false }
        guard p.metadataRead else { return true }
        if !ratings.isEmpty { if !ratings.contains(p.rating) { return false } }
        else if hideRejected, p.isRejected { return false }
        if !labels.isEmpty, !labels.contains(p.label ?? "None") { return false }
        if !dates.isEmpty, !dates.contains(c.buckets.bucket(p.date)) { return false }
        if !looks.isEmpty, !looks.contains(LookKind.of(c.lookKey(p.url))) { return false }
        return true
    }

    /// Substring, or a LIKE mask when the name has * or ?.
    var nameTest: (String) -> Bool {
        let name = self.name
        if name.contains("*") || name.contains("?") {
            let pred = NSPredicate(format: "SELF LIKE[c] %@", name)
            return { pred.evaluate(with: $0) }
        }
        return { $0.localizedCaseInsensitiveContains(name) }
    }

    func ordered(_ photos: [Photo]) -> [Photo] {
        func byName(_ a: Photo, _ b: Photo) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }
        let out = photos.sorted { a, b in
            switch sort {
            case .name: return byName(a, b)
            case .kind: return a.kind == b.kind ? byName(a, b) : a.kind < b.kind
            case .date: return a.date == b.date ? byName(a, b) : a.date < b.date
            case .rating: return a.rating == b.rating ? byName(a, b) : a.rating > b.rating
            }
        }
        return reverse ? out.reversed() : out
    }

    var hasTicks: Bool { !ratings.isEmpty || !labels.isEmpty || !dates.isEmpty || !looks.isEmpty || !kinds.isEmpty || selectedOnly }
    var isActive: Bool { enabled && (!ratings.isEmpty || !labels.isEmpty || !dates.isEmpty || !looks.isEmpty || !kinds.isEmpty || selectedOnly) }

    /// Clears the ticks; name, sort and the gear options stay.
    mutating func reset() { ratings = []; labels = []; dates = []; looks = []; kinds = []; selectedOnly = false }
}

/// `total` = photos with that value (FRV's mm); `shown` = of those, how many pass every filter (nn).
struct RowCount: Equatable {
    var total = 0
    var shown = 0
    var text: String { shown == total ? "\(total)" : "\(shown)/\(total)" }
}

/// The numbers next to each row. Photos whose metadata isn't read yet are counted only in Total and File type.
struct FilterCounts: Equatable {
    var ratings: [Int: RowCount] = [:]
    var labels: [String: RowCount] = [:]
    var dates: [DateBucket: RowCount] = [:]
    var looks: [LookKind: RowCount] = [:]
    var kinds: [String: RowCount] = [:]
    var total = 0, unread = 0
    var incomplete: Bool { unread > 0 }          // → italic counts

    init() {}
    init(_ photos: [Photo], shown: Set<URL>, _ c: FilterContext) {
        total = photos.count
        for p in photos {
            let s = shown.contains(p.url)
            Self.add(&kinds, p.kind, s)
            guard p.metadataRead else { unread += 1; continue }
            Self.add(&ratings, p.rating, s)
            Self.add(&labels, p.label ?? "None", s)
            Self.add(&dates, c.buckets.bucket(p.date), s)
            Self.add(&looks, LookKind.of(c.lookKey(p.url)), s)
        }
    }

    private static func add<K: Hashable>(_ d: inout [K: RowCount], _ k: K, _ shown: Bool) {
        d[k, default: RowCount()].total += 1
        if shown { d[k, default: RowCount()].shown += 1 }
    }
}

// MARK: - White balance presets

struct WBPreset: Identifiable {
    let name: String
    let temp: Float?      // nil = as shot
    var id: String { name }
    static let all: [WBPreset] = [
        WBPreset(name: "As shot", temp: nil),
        WBPreset(name: "Auto", temp: -1),           // computed per photo (grey world)
        WBPreset(name: "Daylight 5500 K", temp: 5500),
        WBPreset(name: "Cloudy 6500 K", temp: 6500),
        WBPreset(name: "Shade 7500 K", temp: 7500),
        WBPreset(name: "Tungsten 3200 K", temp: 3200),
        WBPreset(name: "Fluorescent 4000 K", temp: 4000),
        WBPreset(name: "Flash 5600 K", temp: 5600),
    ]
}

/// How choosing a look in the LUT panel behaves (the LUT panel's three-way switch).
enum LookMode: String, CaseIterable, Identifiable {
    case preview        // the chosen look is shown on every photo; nothing is written, saved looks are not shown
    case apply          // choosing writes the look to the photo's .xmp; photos without one show the last chosen look
    case perPhoto       // each photo shows the look in its .xmp, or Base when it has none; choosing writes it
    var id: String { rawValue }
    var title: String {
        switch self { case .preview: "Preview"; case .apply: "Apply"; case .perPhoto: "Per photo" }
    }
    var help: String {
        switch self {
        case .preview: "Preview: the chosen look is shown on every photo and nothing is written to the .xmp"
        case .apply: "Apply: the chosen look is written to the photo's .xmp and stays chosen for photos without a saved look"
        case .perPhoto: "Per photo: each photo shows the look saved in its .xmp, or Base when there is none; choosing a look writes it"
        }
    }
}
