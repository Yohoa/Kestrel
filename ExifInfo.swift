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
