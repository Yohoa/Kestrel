import Foundation

// Minimal-diff editing of .xmp sidecars (FastRawViewer / Lightroom / Bridge style).
//
// Rules: edit the text in place, touching only the tags asked for (plus xmp:MetadataDate); keep BOM, line
// endings and indentation; refuse (return nil) when the original or the result is not well-formed XML;
// replace the file atomically; new properties go into the OUTER rdf:Description (never a nested one such as
// Lightroom's crs:Look); the app's own settings live in the arwexport: namespace and never overwrite
// FastRawViewer's (libraw:) or Adobe's (crs:) properties — those change only through the XMP panel.

struct XMPChange: Equatable {
    let tag: String        // e.g. "xmp:Rating"
    let value: String?     // nil removes the tag
}

enum XMPEdit {
    static let namespaces: [String: String] = [
        "xmp": "http://ns.adobe.com/xap/1.0/",
        "crs": "http://ns.adobe.com/camera-raw-settings/1.0/",
        "libraw": "http://ns.libraw.com/librawxmp/1.0/",
        "photoshop": "http://ns.adobe.com/photoshop/1.0/",
        "tiff": "http://ns.adobe.com/tiff/1.0/",
        "arwexport": "http://ns.arwexport.app/1.0/",
    ]

    // MARK: escaping

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: cached regular expressions (compiling them per call was a measurable cost on 500 files)

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression {
        regexLock.lock(); defer { regexLock.unlock() }
        if let r = regexCache[pattern] { return r }
        let r = try! NSRegularExpression(pattern: pattern)
        regexCache[pattern] = r
        return r
    }

    private static func elementPattern(_ tag: String) -> String {
        let t = NSRegularExpression.escapedPattern(for: tag)
        return "<\(t)(?:\\s[^<>]*)?>[^<]*</\(t)>|<\(t)\\s*/>"
    }

    private static func attributePattern(_ tag: String) -> String {
        "(?<![\\w:])\(NSRegularExpression.escapedPattern(for: tag))=\"[^\"]*\""
    }

    static func minimalDocument(ext: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 5.6.0">
           <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
                 <photoshop:SidecarForExtension>\(ext.uppercased())</photoshop:SidecarForExtension>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        """
    }

    static func isWellFormed(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return (try? XMLDocument(xmlString: text, options: [])) != nil
    }

    static func isoNow(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: rdf:Description structure

    private struct DescriptionTag {
        enum Kind { case open, selfClosing, close }
        let kind: Kind
        let range: Range<String.Index>
    }

    private static func descriptionTags(in text: String) -> [DescriptionTag] {
        let r = regex("<rdf:Description\\b[^>]*>|</rdf:Description>")
        return r.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let rg = Range(m.range, in: text) else { return nil }
            let t = text[rg]
            if t.hasPrefix("</") { return DescriptionTag(kind: .close, range: rg) }
            return DescriptionTag(kind: t.hasSuffix("/>") ? .selfClosing : .open, range: rg)
        }
    }

    /// How many rdf:Description elements enclose `pos` (1 = directly inside the outer description).
    private static func depth(at pos: String.Index, tags: [DescriptionTag]) -> Int {
        var d = 0
        for t in tags {
            if t.range.lowerBound >= pos { break }
            switch t.kind {
            case .open: d += 1
            case .close: d -= 1
            case .selfClosing: if pos < t.range.upperBound { d += 1 }
            }
            if t.kind == .open && pos < t.range.upperBound { }   // attributes of an open tag count as inside it
        }
        return d
    }

    /// The outer rdf:Description: its opening tag and the matching closing tag (nil when self-closing).
    private static func outerDescription(in text: String) -> (open: Range<String.Index>, selfClosing: Bool, close: Range<String.Index>?)? {
        let tags = descriptionTags(in: text)
        guard let first = tags.first, first.kind != .close else { return nil }
        if first.kind == .selfClosing { return (first.range, true, nil) }
        var d = 0
        for t in tags {
            switch t.kind {
            case .open: d += 1
            case .close:
                d -= 1
                if d == 0 { return (first.range, false, t.range) }
            case .selfClosing: break
            }
        }
        return nil
    }

    /// Ranges of `tag` (element or attribute form) that sit in the outer description itself.
    private static func outerMatches(_ tag: String, in text: String, tags: [DescriptionTag]) -> (elem: Range<String.Index>?, attr: Range<String.Index>?) {
        let whole = NSRange(text.startIndex..., in: text)
        func first(_ pattern: String) -> Range<String.Index>? {
            for m in regex(pattern).matches(in: text, range: whole) {
                guard let rg = Range(m.range, in: text) else { continue }
                // attributes inside the outer open tag are at depth 1; the open tag itself starts before them
                if depth(at: rg.lowerBound, tags: tags) == 1 { return rg }
            }
            return nil
        }
        return (first(elementPattern(tag)), first(attributePattern(tag)))
    }

    // MARK: reading

    static func value(of tag: String, in text: String) -> String? {
        let whole = NSRange(text.startIndex..., in: text)
        let t = NSRegularExpression.escapedPattern(for: tag)
        let tags = descriptionTags(in: text)
        func groupMatch(_ pattern: String) -> String? {
            for m in regex(pattern).matches(in: text, range: whole) {
                guard let all = Range(m.range, in: text), let g = Range(m.range(at: 1), in: text) else { continue }
                if tags.isEmpty || depth(at: all.lowerBound, tags: tags) <= 1 { return unescape(String(text[g])) }
            }
            return nil
        }
        if let v = groupMatch("<\(t)(?:\\s[^<>]*)?>([^<]*)</\(t)>") { return v.trimmingCharacters(in: .whitespacesAndNewlines) }
        return groupMatch("(?<![\\w:])\(t)=\"([^\"]*)\"")
    }

    /// Every simple `<ns:Tag>text</ns:Tag>` element and description attribute, in file order (for display).
    static func simpleFields(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for m in regex("<([A-Za-z]+:[A-Za-z0-9]+)>([^<>]+)</\\1>").matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) {
                let v = unescape(text[b].trimmingCharacters(in: .whitespacesAndNewlines))
                if !v.isEmpty { out.append((String(text[a]), v)) }
            }
        }
        for m in regex("\\s([A-Za-z]+:[A-Za-z0-9]+)=\"([^\"]*)\"").matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) {
                let k = String(text[a])
                if k.hasPrefix("xmlns") || k == "rdf:about" || k == "x:xmptk" { continue }
                out.append((k, unescape(String(text[b]))))
            }
        }
        return out
    }

    // MARK: validation (ISO 16684-1 basics)

    /// Checks the basics of the XMP serialisation: well-formed XML, `x:xmpmeta` root with an `rdf:RDF` child and
    /// at least one `rdf:Description`, every used prefix declared, namespace URIs ending in "/" or "#", the value
    /// formats of the properties we write, and that the properties we write sit in the outer description.
    /// Empty = conformant.
    static func validate(_ text: String) -> [String] {
        var issues: [String] = []
        guard let doc = try? XMLDocument(xmlString: text, options: []) else { return ["Not well-formed XML"] }
        guard let root = doc.rootElement(), root.name == "x:xmpmeta" else { issues.append("Root element is not x:xmpmeta"); return issues }
        if root.namespaces?.first(where: { $0.name == "x" })?.stringValue != "adobe:ns:meta/" { issues.append("x:xmpmeta must declare xmlns:x=\"adobe:ns:meta/\"") }
        if root.elements(forName: "rdf:RDF").isEmpty { issues.append("Missing rdf:RDF") }
        if text.range(of: "<rdf:Description") == nil { issues.append("Missing rdf:Description") }
        if text.range(of: "rdf:about=") == nil { issues.append("rdf:Description has no rdf:about") }

        var declared = Set<String>()
        for m in regex("xmlns:([A-Za-z0-9]+)=\"([^\"]*)\"").matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) {
                declared.insert(String(text[a]))
                let uri = String(text[b])
                if !(uri.hasSuffix("/") || uri.hasSuffix("#")) && String(text[a]) != "x" {
                    issues.append("Namespace URI of \(text[a]) should end with / or #")
                }
            }
        }
        var used = Set<String>()
        for m in regex("(?:<|\\s)([A-Za-z][A-Za-z0-9]*):[A-Za-z][A-Za-z0-9]*[=>/\\s]").matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let a = Range(m.range(at: 1), in: text) { used.insert(String(text[a])) }
        }
        for u in used.subtracting(declared).subtracting(["xmlns", "xml"]).sorted() { issues.append("Prefix \(u): is used but not declared") }

        func check(_ tag: String, _ pattern: String, _ what: String) {
            if let v = value(of: tag, in: text), v.range(of: pattern, options: .regularExpression) == nil {
                issues.append("\(tag) = \"\(v)\" is not \(what)")
            }
        }
        check("xmp:Rating", "^-?[0-5]$", "an integer from -1 to 5")
        check("xmp:MetadataDate", "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}([+-]\\d{2}:\\d{2}|Z)$", "an ISO 8601 date-time")
        check("crs:Exposure2012", "^[+-]?\\d+(\\.\\d+)?$", "a signed decimal")
        check("crs:Temperature", "^\\d+$", "an integer (Kelvin)")
        check("crs:Tint", "^[+-]?\\d+$", "an integer")
        check("libraw:Exposure", "^[+-]?\\d+(\\.\\d+)?$", "a decimal")
        check("arwexport:Exposure", "^[+-]?\\d+(\\.\\d+)?$", "a signed decimal")
        check("tiff:Orientation", "^[1-8]$", "an orientation code from 1 to 8")

        // Our properties must be direct children of the outer description, not inside e.g. crs:Look.
        let tags = descriptionTags(in: text)
        for tag in ["xmp:MetadataDate", "xmp:Rating", "xmp:Label", "arwexport:Version", "arwexport:Look"] {
            let t = NSRegularExpression.escapedPattern(for: tag)
            for m in regex("<\(t)\\b|(?<![\\w:])\(t)=\"").matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let rg = Range(m.range, in: text), depth(at: rg.lowerBound, tags: tags) > 1 {
                    issues.append("\(tag) is inside a nested rdf:Description"); break
                }
            }
        }
        return issues
    }

    // MARK: editing

    /// Applies the changes and refreshes xmp:MetadataDate. Returns nil if the input or result is not valid XML.
    /// When nothing changes the original text comes back untouched (the date is not bumped).
    static func apply(_ changes: [XMPChange], to original: String, touchDate: Date? = Date()) -> String? {
        guard isWellFormed(original) else { return nil }
        let eol = original.contains("\r\n") ? "\r\n" : "\n"
        var text = original
        for c in changes {
            guard let t = set(c, in: text, eol: eol) else { return nil }
            text = t
        }
        if text == original { return original }
        if let d = touchDate {
            var dates = [XMPChange(tag: "xmp:MetadataDate", value: isoNow(d))]
            if value(of: "libraw:MetaDataDate", in: text) != nil { dates.append(XMPChange(tag: "libraw:MetaDataDate", value: isoNow(d))) }
            for c in dates {
                guard let t = set(c, in: text, eol: eol) else { return nil }
                text = t
            }
        }
        return isWellFormed(text) ? text : nil
    }

    private static func set(_ c: XMPChange, in text: String, eol: String) -> String? {
        let tags = descriptionTags(in: text)
        let found = outerMatches(c.tag, in: text, tags: tags)

        if let rg = found.elem {
            guard let v = c.value else { return removing(rg, from: text, lineIfAlone: true) }
            return text.replacingCharacters(in: rg, with: "<\(c.tag)>\(escape(v))</\(c.tag)>")
        }
        if let rg = found.attr {
            guard let v = c.value else { return removing(rg, from: text, lineIfAlone: false) }
            return text.replacingCharacters(in: rg, with: "\(c.tag)=\"\(escape(v))\"")
        }
        guard let v = c.value else { return text }          // nothing to remove

        // Insert a new element into the OUTER rdf:Description.
        var work = text
        let prefix = String(c.tag.split(separator: ":").first ?? "")
        // Declared on the outer description or an ancestor (x:xmpmeta, rdf:RDF)? Not "somewhere in the file":
        // exiftool-style files declare each prefix in its own top-level block, which would not cover this one.
        guard let outer0 = outerDescription(in: work) else { return nil }
        if !work[..<outer0.open.upperBound].contains("xmlns:\(prefix)="), let uri = namespaces[prefix] {
            guard let open = outerDescription(in: work) else { return nil }
            let tagText = String(work[open.open])
            let closer = open.selfClosing ? "/>" : ">"
            var head = String(tagText.dropLast(closer.count))
            while head.last?.isWhitespace == true { head.removeLast() }
            work.replaceSubrange(open.open, with: head + " xmlns:\(prefix)=\"\(uri)\"" + closer)
        }
        guard let outer = outerDescription(in: work) else { return nil }
        let line = "<\(c.tag)>\(escape(v))</\(c.tag)>"
        if outer.selfClosing {
            let tagText = String(work[outer.open])
            let head = String(tagText.dropLast(2)).trimmingCharacters(in: .whitespaces)
            let indent = lineIndent(before: outer.open.lowerBound, in: work)
            work.replaceSubrange(outer.open, with: head + ">" + eol + indent + "   " + line + eol + indent + "</rdf:Description>")
            return work
        }
        guard let close = outer.close else { return nil }
        let closeIndent = lineIndent(before: close.lowerBound, in: work)
        // Match the indentation of the existing direct children when there are any.
        let between = String(work[outer.open.upperBound..<close.lowerBound])
        var childIndent = closeIndent + "   "
        if let m = regex("\\n([ \\t]+)<[A-Za-z]").firstMatch(in: between, range: NSRange(between.startIndex..., in: between)),
           let g = Range(m.range(at: 1), in: between) { childIndent = String(between[g]) }
        let insertAt = work.index(close.lowerBound, offsetBy: -closeIndent.count)
        if work[insertAt..<close.lowerBound] == closeIndent[...] {
            work.insert(contentsOf: childIndent + line + eol, at: insertAt)
        } else {
            work.insert(contentsOf: eol + childIndent + line + eol, at: close.lowerBound)
        }
        return work
    }

    private static func lineIndent(before idx: String.Index, in text: String) -> String {
        let lineStart = text[..<idx].lastIndex(where: { $0 == "\n" }).map { text.index(after: $0) } ?? text.startIndex
        return String(text[lineStart..<idx].prefix(while: { $0 == " " || $0 == "\t" }))
    }

    /// Removes the matched range; when `lineIfAlone` and it is the only thing on its line, removes the whole line.
    private static func removing(_ rg: Range<String.Index>, from text: String, lineIfAlone: Bool) -> String {
        var s = text
        var lower = rg.lowerBound, upper = rg.upperBound
        if lineIfAlone {
            let lineStart = s[..<lower].lastIndex(where: { $0 == "\n" }).map { s.index(after: $0) } ?? s.startIndex
            let beforeIsBlank = s[lineStart..<lower].allSatisfy { $0 == " " || $0 == "\t" }
            var after = upper
            while after < s.endIndex, s[after] == " " || s[after] == "\t" { after = s.index(after: after) }
            if beforeIsBlank, after < s.endIndex, s[after] == "\n" || s[after] == "\r" {
                if s[after] == "\r" { after = s.index(after: after) }
                if after < s.endIndex, s[after] == "\n" { after = s.index(after: after) }
                lower = lineStart; upper = after
            }
        } else {
            while lower > s.startIndex, s[s.index(before: lower)] == " " { lower = s.index(before: lower) }
        }
        s.removeSubrange(lower..<upper)
        return s
    }
}

// MARK: - Develop settings in the sidecar (XMP standard extension namespace)

/// The app's own settings live in its own namespace, `arwexport:`, which is how XMP is meant to be extended.
/// Nothing here touches `crs:` (Adobe) or `libraw:` (FastRawViewer) properties: their scales differ from this
/// app's (a Core Image Kelvin is not an Adobe Kelvin; Adobe's exposure carries a hidden baseline), so changing
/// them silently would change what Lightroom or FastRawViewer show. Use the XMP panel to write those on purpose.
enum DevelopXMP {
    /// Removes every develop tag this app writes (an edit undone back to "never edited").
    static let removalChanges = changes(for: PhotoState()).map { XMPChange(tag: $0.tag, value: nil) }

    static func changes(for s: PhotoState) -> [XMPChange] {
        var c: [XMPChange] = [
            XMPChange(tag: "arwexport:Version", value: "1"),
            XMPChange(tag: "arwexport:Exposure", value: String(format: "%+.2f", s.ev)),
            XMPChange(tag: "arwexport:HighlightRecovery", value: s.hl ? "True" : "False"),
            XMPChange(tag: "arwexport:Contrast", value: s.contrast == 0 ? nil : String(format: "%+.1f", s.contrast)),
            XMPChange(tag: "arwexport:Look", value: s.look),
            XMPChange(tag: "arwexport:LookInput", value: nil),    // briefly written per photo; the LUT folder keeps it now
        ]
        if let t = s.temp {
            c.append(XMPChange(tag: "arwexport:WhiteBalance", value: "Custom"))
            c.append(XMPChange(tag: "arwexport:Temperature", value: String(Int(t.rounded()))))
            c.append(XMPChange(tag: "arwexport:Tint", value: String(Int((s.tint ?? 0).rounded()))))
        } else {
            c.append(XMPChange(tag: "arwexport:WhiteBalance", value: "As Shot"))
            c.append(XMPChange(tag: "arwexport:Temperature", value: nil))
            c.append(XMPChange(tag: "arwexport:Tint", value: nil))
        }
        return c
    }

    /// The state this app wrote earlier, or nil when the sidecar has no `arwexport:` settings.
    static func state(from text: String) -> PhotoState? {
        guard XMPEdit.value(of: "arwexport:Version", in: text) != nil else { return nil }
        var s = PhotoState()
        s.ev = XMPEdit.value(of: "arwexport:Exposure", in: text).flatMap { Float($0) } ?? 0
        s.hl = XMPEdit.value(of: "arwexport:HighlightRecovery", in: text) != "False"
        s.look = XMPEdit.value(of: "arwexport:Look", in: text).flatMap { $0.isEmpty ? nil : $0 }
        s.contrast = XMPEdit.value(of: "arwexport:Contrast", in: text).flatMap { Float($0) }.map { max(-5, min(5, ($0 * 10).rounded() / 10)) } ?? 0   // "+2" or "+1.5"
        if XMPEdit.value(of: "arwexport:WhiteBalance", in: text) == "Custom" {
            s.temp = XMPEdit.value(of: "arwexport:Temperature", in: text).flatMap { Float($0) }
            s.tint = XMPEdit.value(of: "arwexport:Tint", in: text).flatMap { Float($0) }
        }
        return s
    }
}

// MARK: - Files

/// Every sidecar write goes through this one serial queue, so two writers can never interleave their
/// read → edit → replace on the same file (a rating press and a develop save used to lose each other's update).
final class SidecarWriter {
    static let shared = SidecarWriter()
    private let queue = DispatchQueue(label: "arwexport.sidecar", qos: .userInitiated)

    /// Runs `work` after everything submitted before it, off the caller's thread.
    func run<T>(_ work: @escaping () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { (c: CheckedContinuation<Result<T, Error>, Never>) in
            queue.async { c.resume(returning: Result { try work() }) }
        }
    }

    /// Puts `work` on the queue right now (so a quit that follows cannot miss it) and reports on the main queue.
    func submit<T>(_ work: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let r = Result { try work() }
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Blocks until every queued write has finished (used when the app quits).
    func drain() { queue.sync {} }

    /// Synchronous variant for the quit path: runs after everything queued before it.
    func runSync(_ work: () -> Void) { queue.sync(execute: work) }
}

/// Reading and (atomically) writing the sidecar next to a RAW file.
enum XMPFile {
    static func url(for raw: URL) -> URL { raw.deletingPathExtension().appendingPathExtension("xmp") }
    static func backupURL(for raw: URL) -> URL { raw.deletingPathExtension().appendingPathExtension("xmp.kestrel-backup") }
    /// The name earlier versions used (the app was called ARWExport): still recognised, and moved along with the RAW.
    static func oldBackupURL(for raw: URL) -> URL { raw.deletingPathExtension().appendingPathExtension("xmp.arwexport-backup") }

    static func read(_ raw: URL) -> (text: String, bom: Bool)? {
        guard let data = try? Data(contentsOf: url(for: raw)) else { return nil }
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard let s = String(data: bom ? data.dropFirst(3) : data, encoding: .utf8) else { return nil }
        return (s, bom)
    }

    struct WriteError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Saves the app's develop settings (arwexport: namespace only) into the sidecar.
    /// The sidecar copied next to an export. The exported picture is already turned, so a tiff:Orientation in the
    /// copy would turn it a second time in an app that reads it: that tag is left out.
    /// The same goes for this app's develop settings: the export has them baked in, and Kestrel opens HEIC files,
    /// so a copy that kept them would show the look and exposure a second time.
    static func copyForExport(_ sc: Sidecar, to x: URL) {
        let strip = DevelopXMP.removalChanges + [XMPChange(tag: "tiff:Orientation", value: nil)]
        guard let t = XMPEdit.apply(strip, to: sc.text, touchDate: nil) else {
            try? FileManager.default.copyItem(at: sc.url, to: x); return
        }
        try? Data(t.utf8).write(to: x, options: .atomic)
    }

    /// nil: undone back to "never edited", our tags removed. `rot` is the turn to keep either way (an undo to
    /// "never edited" puts back the one the sidecar had).
    static func saveDevelop(_ state: PhotoState?, rot: Int, for raw: URL) throws {
        try write(state.map(DevelopXMP.changes) ?? DevelopXMP.removalChanges, for: raw, rot: rot)
    }

    /// The tiff:Orientation change for turn `rot`, if the sidecar doesn't already say that. FastRawViewer, Lightroom
    /// and Bridge read this tag, so they turn the photo the same way. Left alone when it already agrees (absent
    /// counts as no turn), so editing an unturned photo never adds it; an unturned photo that had one gets the
    /// camera's own code back rather than losing the tag.
    private static func orientationChange(rot: Int, in text: String, raw: URL) -> XMPChange? {
        let existing = XMPEdit.value(of: "tiff:Orientation", in: text).flatMap { Int($0) }
        if existing == nil && rot == 0 { return nil }
        if let e = existing, Orientation.quarter(e) == nil { if rot == 0 { return nil } }   // mirrored: only replaced by a real turn
        let cam = Orientation.camera(raw)
        if let e = existing, Orientation.quarter(e) != nil, Orientation.rot(sidecarCode: e, camera: cam) == rot { return nil }
        return XMPChange(tag: "tiff:Orientation", value: String(Orientation.code(cam + rot)))
    }

    /// Applies `changes` to the sidecar (creating a minimal one if missing). Keeps a one-time backup.
    /// Call it through `SidecarWriter` so writes to one file never overlap. With `rot`, tiff:Orientation follows it.
    static func write(_ changes: [XMPChange], for raw: URL, rot: Int? = nil) throws {
        // the photo was moved (to _Rejected) by a move queued before this write: its sidecar went with it, so
        // writing here would leave a stray one behind (and ⌘Z would then keep the real one in _Rejected)
        guard FileManager.default.fileExists(atPath: raw.path) else { return }
        ScanIndex.shared.sidecarSeen(url(for: raw))       // it exists from now on (or is about to)
        let existing = read(raw)
        let base = existing?.text ?? XMPEdit.minimalDocument(ext: raw.pathExtension)
        var changes = changes
        // an export's copy of its RAW's sidecar, edited here for the first time: it becomes this file's own, and the
        // RAW's settings in it (already baked into the picture) go first, so they can't come back
        if let e = XMPEdit.value(of: "photoshop:SidecarForExtension", in: base), !e.isEmpty, e.lowercased() != raw.pathExtension.lowercased() {
            changes = DevelopXMP.removalChanges + [XMPChange(tag: "tiff:Orientation", value: nil),
                                                   XMPChange(tag: "photoshop:SidecarForExtension", value: raw.pathExtension.uppercased())] + changes
        }
        if let rot, let o = orientationChange(rot: rot, in: XMPEdit.apply(changes, to: base, touchDate: nil) ?? base, raw: raw) { changes.append(o) }
        guard let edited = XMPEdit.apply(changes, to: base) else {
            throw WriteError(message: "Refused: \(url(for: raw).lastPathComponent) is not well-formed XML or the edit would break it")
        }
        if edited == base { return }          // nothing to change — and never create an empty sidecar
        let before = Set(XMPEdit.validate(base)), after = XMPEdit.validate(edited)
        let introduced = after.filter { !before.contains($0) }
        if !introduced.isEmpty { throw WriteError(message: "Refused: the edit would break XMP conformance — " + introduced.joined(separator: "; ")) }
        let fm = FileManager.default
        // One backup of a sidecar another program wrote (FastRawViewer, Lightroom, Capture One), taken the first time
        // this app edits it: if an edit ever damaged someone else's file, the original is still there. A sidecar
        // this app created or has already edited (it has arwexport: tags) needs none.
        if let existing, !existing.text.contains("arwexport:"), !fm.fileExists(atPath: backupURL(for: raw).path),
           !fm.fileExists(atPath: oldBackupURL(for: raw).path) {
            try? fm.copyItem(at: url(for: raw), to: backupURL(for: raw))
        }
        var data = Data()
        if existing?.bom == true { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(edited.utf8))
        try data.write(to: url(for: raw), options: .atomic)
    }
}

// MARK: - Parsed sidecar

struct Sidecar {
    var url: URL
    var rating: Int
    var label: String?
    var exposure: Float?        // libraw:Exposure (FastRawViewer), else crs:Exposure2012
    var temperature: Float?     // crs:Temperature
    var tint: Float?            // crs:Tint
    var text: String
    var develop: PhotoState?    // settings this app saved (arwexport: namespace), if any
    var orientation: Int?       // tiff:Orientation (FastRawViewer, Lightroom, or this app's rotation)
    var content: (info: ContentInfo, rot: Int)? { ContentAnalysis.saved(in: text) }

    static func url(for raw: URL) -> URL { XMPFile.url(for: raw) }

    /// False when the sidecar says it was written for another file type (photoshop:SidecarForExtension "ARW" next
    /// to a HEIC): an export's copy of its RAW's sidecar, whose settings are already baked into the picture.
    func belongs(to photo: URL) -> Bool {
        guard let e = XMPEdit.value(of: "photoshop:SidecarForExtension", in: text), !e.isEmpty else { return true }
        return e.lowercased() == photo.pathExtension.lowercased()
    }

    static func load(for raw: URL) -> Sidecar? {
        guard let (s, _) = XMPFile.read(raw) else { return nil }
        return parse(s, url: XMPFile.url(for: raw))
    }

    static func parse(_ s: String, url: URL) -> Sidecar {
        func num(_ tag: String) -> Float? { XMPEdit.value(of: tag, in: s).flatMap { Float($0) } }
        let libraw = num("libraw:Exposure"), crs = num("crs:Exposure2012")
        // FastRawViewer leaves crs:Exposure2012 at 0 and stores its correction in libraw:Exposure.
        let exposure = (libraw != nil && libraw != 0) ? libraw : crs ?? libraw
        let label = XMPEdit.value(of: "xmp:Label", in: s).flatMap { $0.isEmpty ? nil : $0 }
        return Sidecar(url: url,
                       rating: XMPEdit.value(of: "xmp:Rating", in: s).flatMap { Int($0) }.map { max(-1, min(5, $0)) } ?? 0,   // other tools' odd values
                       label: label, exposure: exposure, temperature: num("crs:Temperature"), tint: num("crs:Tint"),
                       text: s, develop: DevelopXMP.state(from: s),
                       orientation: XMPEdit.value(of: "tiff:Orientation", in: s).flatMap { Int($0) })
    }
}
