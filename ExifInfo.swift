import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ExifInfo {
    /// EXIF DateTimeOriginal ("2026:10:25 17:00:12"), read in the camera's local time.
    static func captureDate(_ url: URL) -> Date? { capture(url).date }

    /// The capture date and "make model lens" (what the name filter also searches), from one read of the file.
    static func capture(_ url: URL) -> (date: Date?, gear: String) {
        guard Storage.isSlow(url) else { return readCapture(CGImageSourceCreateWithURL(url as CFURL, nil)) }
        if let c = LocalCache.capture(url) { return c }
        // The EXIF sits in the first 256 KB: one read of those, parsed from memory (with the type, or ImageIO
        // refuses a partial RAW), costs one round trip to the share instead of an open per small read.
        let hint = UTType(filenameExtension: url.pathExtension)?.identifier ?? ""
        let c: (date: Date?, gear: String)
        if let d = Storage.head(url, bytes: 256 << 10),
           case let fromData = readCapture(CGImageSourceCreateWithData(d as CFData, [kCGImageSourceTypeIdentifierHint: hint] as CFDictionary)),
           fromData.date != nil {                       // no date: the EXIF lies further in, read the file
            c = fromData
        } else {
            c = readCapture(CGImageSourceCreateWithURL(url as CFURL, nil))
        }
        LocalCache.storeCapture(c, for: url)
        return c
    }

    private static func readCapture(_ src: CGImageSource?) -> (date: Date?, gear: String) {
        guard let src,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (nil, "") }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gear = [tiff[kCGImagePropertyTIFFMake], tiff[kCGImagePropertyTIFFModel], exif[kCGImagePropertyExifLensModel]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return (parseDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String), gear)
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return exifDate.date(from: s)
    }

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// Lens model and pixel width, without building the whole EXIF list.
    static func lensAndWidth(_ url: URL) -> (lens: String, width: Int) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return ("", 0) }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        return (exif[kCGImagePropertyExifLensModel] as? String ?? "", p[kCGImagePropertyPixelWidth] as? Int ?? 0)
    }

    static func read(_ url: URL) -> (lines: [(String, String)], size: String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return ([], "") }
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var lines: [(String, String)] = []
        var exposure: [String] = []
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            exposure.append(t >= 1 ? String(format: "%.1fs", t) : "1/\(Int((1 / t).rounded()))")
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { exposure.append(String(format: "f/%.1f", f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { lines.append(("Exposure", exposure.joined(separator: "  "))) }
        if let b = exif[kCGImagePropertyExifExposureBiasValue] as? Double { lines.append(("Comp.", String(format: "%+.1f EV", b))) }
        if let a = sonyStdAdjustTag(url) { lines.append(("Std. adj.", a == 0 ? "Off" : String(format: "%+.1f EV", a))) }   // Sony only
        if let f = exif[kCGImagePropertyExifFocalLength] as? Double { lines.append(("Focal", String(format: "%.0f mm", f))) }
        if let l = exif[kCGImagePropertyExifLensModel] as? String { lines.append(("Lens", l)) }
        if let m = tiff[kCGImagePropertyTIFFModel] as? String { lines.append(("Camera", m)) }
        if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String { lines.append(("Date", d)) }
        var size = ""
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            size = "\(w)x\(h)"
            lines.append(("Size", size))
        }
        return (lines, size)
    }
}

// MARK: - Sony "Exposure Std. Adjust"

extension ExifInfo {
    /// Sony's Exposure Std. Adjust (a camera menu setting that shifts the meter's standard and so exposes every shot
    /// darker or brighter) from MakerNote tag 0x202D, in EV: a signed rational in sixths of a stop ("-6/6" = -1 EV,
    /// "0/6" = off). Found in the ARW and the camera's JPG alike. 0 for other makes or when it can't be read.
    /// The tag sits in the first few KB; ImageIO doesn't expose Sony's MakerNote, so it is read from the TIFF here.
    static func sonyStdAdjust(_ url: URL) -> Float { sonyStdAdjustTag(url) ?? 0 }

    /// The same, nil when the file is not a Sony one or has no such tag (the EXIF box then shows no line).
    static func sonyStdAdjustTag(_ url: URL) -> Float? {
        guard var d = Storage.head(url, bytes: 128 << 10), d.count > 16 else { return nil }
        if d.starts(with: [0xFF, 0xD8]) {                                    // JPEG: the TIFF starts after "Exif\0\0"
            guard let r = d.range(of: Data("Exif\0\0".utf8)) else { return nil }
            d = d.subdata(in: r.upperBound..<d.count)
        }
        guard d.count >= 16 else { return nil }
        let b = [UInt8](d)
        let little: Bool
        switch (b[0], b[1]) { case (0x49, 0x49): little = true; case (0x4D, 0x4D): little = false; default: return nil }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= b.count else { return nil }
            return little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard let lo = u16(little ? o : o + 2), let hi = u16(little ? o + 2 : o) else { return nil }
            return hi << 16 | lo
        }
        /// Tag → (type, count, offset of the value field).
        func ifd(_ o: Int) -> [Int: (type: Int, count: Int, at: Int)] {
            guard let n = u16(o), n < 1000 else { return [:] }
            var out: [Int: (type: Int, count: Int, at: Int)] = [:]
            for i in 0..<n {
                let e = o + 2 + 12 * i
                guard let tag = u16(e), let type = u16(e + 2), let count = u32(e + 4) else { break }
                out[tag] = (type, count, e + 8)
            }
            return out
        }
        guard let first = u32(4) else { return nil }
        let ifd0 = ifd(first)
        // only Sony's MakerNote has this layout
        guard let make = ifd0[0x010F], let mo = make.count > 4 ? u32(make.at) : make.at, mo + 4 <= b.count,
              String(decoding: b[mo..<mo + 4], as: UTF8.self).uppercased() == "SONY",
              let exifAt = ifd0[0x8769], let exif = u32(exifAt.at),
              let note = ifd(exif)[0x927C], let notePos = u32(note.at) else { return nil }
        let start = notePos + 12 <= b.count && String(decoding: b[notePos..<notePos + 4], as: UTF8.self) == "SONY" ? notePos + 12 : notePos
        guard let t = ifd(start)[0x202D], t.type == 10, t.count == 1, let p = u32(t.at),
              let num = u32(p), let den = u32(p + 4), den != 0 else { return nil }
        return Float(Int32(truncatingIfNeeded: num)) / Float(Int32(truncatingIfNeeded: den))
    }
}
