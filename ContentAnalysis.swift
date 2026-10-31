import Foundation
import CoreGraphics
import ImageIO
import Vision

// What's in the photo, from Apple's Vision framework (on this Mac, on the Neural Engine where macOS chooses it):
// labels, an aesthetics score and the main subject. Run on the camera's embedded preview of the photo on screen
// only (Settings ▸ Content analysis), never for a whole folder.

struct ContentInfo {
    var labels: [(name: String, confidence: Float)] = []
    var aesthetics: Float?           // -1 (poor) … 1 (great); macOS 15+
    var utility = false              // a screenshot, receipt, document … rather than a memorable photo
    var subject: CGRect?             // the main subject, 0…1 of the turned picture, origin top-left
    var ms = 0                       // how long the analysis took
}

enum ContentAnalysis {
    static let settingKey = "contentAnalysis"

    /// About 1000 px is what Vision works at anyway; the embedded preview is read in ~10 ms.
    static func analyze(_ url: URL, rot: Int) -> ContentInfo? {
        let t0 = Date()
        Storage.warmHead(url)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg0 = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary),
              let cg = Orientation.rotate(cg0, rot) else { return nil }

        let classify = VNClassifyImageRequest()
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        var requests: [VNRequest] = [classify, saliency]
        var aesthetic: VNRequest?
        if #available(macOS 15, *) {
            let a = VNCalculateImageAestheticsScoresRequest()
            aesthetic = a
            requests.append(a)
        }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform(requests) } catch { return nil }

        var info = ContentInfo()
        // Apple's suggested cut: keep a label only where it is right at least 90 % of the time it is given
        info.labels = (classify.results ?? [])
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(8)
            .map { (pretty($0.identifier), $0.confidence) }
        if #available(macOS 15, *), let a = (aesthetic as? VNCalculateImageAestheticsScoresRequest)?.results?.first {
            info.aesthetics = a.overallScore
            info.utility = a.isUtility
        }
        // all the salient objects together (usually one or two); Vision's origin is bottom-left
        if let objs = saliency.results?.first?.salientObjects, !objs.isEmpty {
            let r = objs.map(\.boundingBox).reduce(objs[0].boundingBox) { $0.union($1) }
            info.subject = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }
        info.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return info
    }

    // MARK: in the sidecar

    /// The results are saved in the app's own namespace (Lightroom's keywords, dc:subject, are left alone):
    /// arwexport:ContentLabels "Cat 83, Food 79" (name and confidence %), arwexport:Aesthetics "+0.41",
    /// arwexport:Utility "True", arwexport:Subject "x,y,w,h" (0…1 from the top-left of the picture turned by
    /// arwexport:ContentRotation). Read back, they spare the analysis next time.
    static func changes(_ i: ContentInfo, rot: Int) -> [XMPChange] {
        [
            XMPChange(tag: "arwexport:ContentVersion", value: "1"),
            XMPChange(tag: "arwexport:ContentLabels", value: i.labels.map { "\($0.name) \(Int(($0.confidence * 100).rounded()))" }.joined(separator: ", ")),
            XMPChange(tag: "arwexport:Aesthetics", value: i.aesthetics.map { String(format: "%+.2f", $0) }),
            XMPChange(tag: "arwexport:Utility", value: i.utility ? "True" : nil),
            XMPChange(tag: "arwexport:Subject", value: i.subject.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.minX, $0.minY, $0.width, $0.height) }),
            XMPChange(tag: "arwexport:ContentRotation", value: rot == 0 ? nil : String(rot)),
        ]
    }

    /// What `changes` saved, and for which turn; nil when the sidecar has none.
    static func saved(in text: String) -> (info: ContentInfo, rot: Int)? {
        guard XMPEdit.value(of: "arwexport:ContentVersion", in: text) != nil else { return nil }
        var i = ContentInfo()
        i.labels = (XMPEdit.value(of: "arwexport:ContentLabels", in: text) ?? "").components(separatedBy: ", ").compactMap { part in
            guard let sp = part.lastIndex(of: " "), let c = Float(part[part.index(after: sp)...]) else { return nil }
            return (String(part[..<sp]), c / 100)
        }
        i.aesthetics = XMPEdit.value(of: "arwexport:Aesthetics", in: text).flatMap { Float($0) }
        i.utility = XMPEdit.value(of: "arwexport:Utility", in: text) == "True"
        if let s = XMPEdit.value(of: "arwexport:Subject", in: text)?.split(separator: ",").compactMap({ Double($0) }), s.count == 4 {
            i.subject = CGRect(x: s[0], y: s[1], width: s[2], height: s[3])
        }
        return (i, XMPEdit.value(of: "arwexport:ContentRotation", in: text).flatMap { Int($0) } ?? 0)
    }

    /// "sky_scene" → "Sky scene"
    static func pretty(_ id: String) -> String {
        let s = id.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}
