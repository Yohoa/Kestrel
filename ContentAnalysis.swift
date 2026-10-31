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

    /// "sky_scene" → "Sky scene"
    static func pretty(_ id: String) -> String {
        let s = id.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}
