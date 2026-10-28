import Foundation
import ImageIO
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// Slow storage: network shares (SMB / AFP / NFS / WebDAV), external drives and SD cards.
//
// Measured on an SMB share over gigabit (24 MP ARW, ~49 MB): small reads are bound by the round trip, big
// sequential reads are cheap. CIRAWFilter decoding straight from the share took 1.7 s per photo; reading the file
// first in 4 MB chunks (the bytes are dropped, the system keeps them cached) and then decoding took 0.74 s.
// A 360 px thumbnail went from 154 to 91 ms, EXIF from 91 to 57 ms, once the start of the file was read in one go.
// So on slow storage: read a RAW in big chunks before decoding it (the neighbour prefetch does the same for the next
// photo), let thumbnails and metadata wait while the photo on screen is being read, and keep thumbnails and EXIF in a
// cache on the Mac's own disk. An extra read-ahead of further photos was tried and made stepping slower: on a
// gigabit link the photo on screen and its neighbour already use most of the time between two steps.

enum Storage {
    private static var slowByVolume: [URL: Bool] = [:]
    private static let lock = NSLock()

    /// On a network share or an external / removable drive, not the Mac's own disk.
    static func isSlow(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/Volumes/") else { return false }
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeIsLocalKey, .volumeIsInternalKey]
        guard let v = try? url.resourceValues(forKeys: keys), let vol = v.volume else { return true }
        lock.lock(); defer { lock.unlock() }
        if let s = slowByVolume[vol] { return s }
        let s = v.volumeIsLocal == false || v.volumeIsInternal != true
        slowByVolume[vol] = s
        return s
    }

    /// Reads the first `bytes` of the file (all of it by default) in 4 MB chunks and drops them, so the parser's
    /// many small reads afterwards come from the system cache instead of one round trip each. Stops early once
    /// `wanted` says the photo is no longer needed (stepped past), so the link is free for the next one.
    static func warm(_ url: URL, bytes: Int = .max, wanted: () -> Bool = { true }) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        var left = bytes
        while left > 0, wanted() {
            let n = autoreleasepool { (try? h.read(upToCount: min(4 << 20, left)))?.count ?? 0 }
            if n == 0 { break }
            left -= n
        }
    }

    // Whole files read recently (by the read-ahead or a decode), so the same RAW is not read twice in a row.
    private static var warmed: [URL] = []

    /// Reads the whole file once, on slow storage only; the RAW decoder calls this before opening the file.
    /// Not for a file above 400 MB: no RAW is that big (a 150 MP IIQ is ~300 MB), so it is something misnamed.
    static func warmWholeFile(_ url: URL) {
        guard isSlow(url) else { return }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 400 << 20 { return }
        lock.lock()
        if warmed.contains(url) { lock.unlock(); return }
        warmed.append(url)
        if warmed.count > 6 { warmed.removeFirst() }
        lock.unlock()
        warm(url, wanted: { RenderScheduler.shared.isWanted(url) })
    }

    /// The first `bytes` of the file, in one read.
    static func head(_ url: URL, bytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: bytes)
    }

    /// Before reading EXIF or an embedded thumbnail / preview: the start of the file in one read.
    static func warmHead(_ url: URL, bytes: Int = 1 << 20) { if isSlow(url) { warm(url, bytes: bytes) } }
}

/// What the folder scan already learned while listing: each RAW's size and date (the cache key) and which `.xmp`
/// files exist. On a network share, a `stat` or a failed open per photo waits behind the listing still running;
/// with this the metadata readers skip both.
final class ScanIndex {
    static let shared = ScanIndex()
    private let lock = NSLock()
    private var stamps: [String: (size: Int, date: Date)] = [:]
    private var sidecars: Set<String> = []          // lowercased .xmp paths seen
    private var listed: Set<String> = []            // lowercased folders whose files were all seen

    func reset() { lock.lock(); stamps = [:]; sidecars = []; listed = []; lock.unlock() }
    func folderListed(_ dir: URL) { lock.lock(); listed.insert(dir.path.lowercased()); lock.unlock() }
    func sidecarSeen(_ xmp: URL) { lock.lock(); sidecars.insert(xmp.path.lowercased()); lock.unlock() }
    func stampSeen(_ url: URL, size: Int, date: Date) { lock.lock(); stamps[url.path] = (size, date); lock.unlock() }

    func stamp(_ url: URL) -> (size: Int, date: Date)? { lock.lock(); defer { lock.unlock() }; return stamps[url.path] }

    /// The scan listed the RAW's folder and saw no sidecar for it.
    func knownWithoutSidecar(_ raw: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return listed.contains(raw.deletingLastPathComponent().path.lowercased())
            && !sidecars.contains(XMPFile.url(for: raw).path.lowercased())
    }
}

/// Thumbnails and EXIF of photos on slow storage, kept in the Mac's cache folder: a folder on a share opens with its
/// filmstrip and filters at once the second time. Keyed by path, size and modification date, so a changed file is
/// read again. Trimmed to `limit` (oldest first) at launch.
enum LocalCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Kestrel", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("exif"), withIntermediateDirectories: true)
        return d
    }()
    static let limit = 500 << 20

    private static func key(_ url: URL) -> String? {
        let size: Int, date: Date
        if let s = ScanIndex.shared.stamp(url) { (size, date) = s }
        else {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let sz = v.fileSize, let d = v.contentModificationDate else { return nil }
            (size, date) = (sz, d)
        }
        let s = "\(url.path)|\(size)|\(date.timeIntervalSince1970)"
        return SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: thumbnails

    static func thumb(_ url: URL) -> NSImage? {
        guard let k = key(url) else { return nil }
        let f = dir.appendingPathComponent("thumbs/\(k).jpg")
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    static func storeThumb(_ cg: CGImage, for url: URL) {
        guard let k = key(url) else { return }
        let f = dir.appendingPathComponent("thumbs/\(k).jpg")
        guard let d = CGImageDestinationCreateWithURL(f as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    // MARK: EXIF capture date and gear

    static func capture(_ url: URL) -> (date: Date?, gear: String)? {
        guard let k = key(url), let d = try? Data(contentsOf: dir.appendingPathComponent("exif/\(k)")),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return nil }
        return (p["date"] as? Date, p["gear"] as? String ?? "")
    }

    static func storeCapture(_ c: (date: Date?, gear: String), for url: URL) {
        guard let k = key(url) else { return }
        var p: [String: Any] = ["gear": c.gear]
        if let d = c.date { p["date"] = d }
        guard let d = try? PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0) else { return }
        try? d.write(to: dir.appendingPathComponent("exif/\(k)"), options: .atomic)
    }

    /// Removes the least recently written entries until the cache is under `limit`.
    static func trim() {
        DispatchQueue.global(qos: .background).async {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let fm = FileManager.default
            var files: [(URL, Int, Date)] = []
            for sub in ["thumbs", "exif"] {
                for f in (try? fm.contentsOfDirectory(at: dir.appendingPathComponent(sub), includingPropertiesForKeys: keys)) ?? [] {
                    let v = try? f.resourceValues(forKeys: Set(keys))
                    files.append((f, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast))
                }
            }
            var total = files.reduce(0) { $0 + $1.1 }
            for (f, size, _) in files.sorted(by: { $0.2 < $1.2 }) where total > limit {
                try? fm.removeItem(at: f)
                total -= size
            }
        }
    }
}

/// The files ⌘C puts on the clipboard next to the picture, so Finder pastes a real file and Mail / Messages attach
/// one. Each copy gets its own folder (the file keeps the photo's name). A copy has to outlive the paste, so old ones
/// go only at launch: everything older than a day, and the oldest beyond 300 MB.
enum ClipboardFiles {
    static let dir = LocalCache.dir.appendingPathComponent("Clipboard", isDirectory: true)
    static let limit = 300 << 20

    static func write(_ data: Data, name: String) -> URL? {
        let d = dir.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        let f = d.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try data.write(to: f, options: .atomic)
            return f
        } catch { return nil }
    }

    static func trim() {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
            var copies: [(URL, Date, Int)] = []
            for d in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
                let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let size = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys)) ?? [])
                    .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
                copies.append((d, date, size))
            }
            var total = copies.reduce(0) { $0 + $1.2 }
            let dayAgo = Date().addingTimeInterval(-86_400)
            for (d, date, size) in copies.sorted(by: { $0.1 < $1.1 }) where date < dayAgo || total > limit {
                try? fm.removeItem(at: d)
                total -= size
            }
        }
    }
}
