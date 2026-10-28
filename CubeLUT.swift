import Foundation

/// A parsed Adobe/Resolve `.cube` 3D LUT, ready for CIColorCube (red varies fastest, RGBA float).
final class CubeLUT {
    let size: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    let data: Data

    var hasDefaultDomain: Bool { domainMin == .zero && domainMax == SIMD3(repeating: 1) }

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private init(size: Int, domainMin: SIMD3<Float>, domainMax: SIMD3<Float>, data: Data) {
        self.size = size; self.domainMin = domainMin; self.domainMax = domainMax; self.data = data
    }

    private static var cache: [String: CubeLUT] = [:]
    private static let lock = NSLock()

    static func load(_ url: URL) throws -> CubeLUT {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attrs[.size] ?? 0)"
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let lut = try parse(try String(contentsOf: url, encoding: .utf8))
        cache[key] = lut
        return lut
    }

    static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var dmin = SIMD3<Float>(0, 0, 0)
        var dmax = SIMD3<Float>(1, 1, 1)
        var values: [Float] = []
        func triple(_ parts: [Substring]) -> SIMD3<Float>? {
            guard parts.count >= 3, let a = Float(parts[0]), let b = Float(parts[1]), let c = Float(parts[2]) else { return nil }
            return SIMD3(a, b, c)
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0].uppercased() {
            case "TITLE": continue
            case "LUT_1D_SIZE": throw ParseError(message: "1D .cube LUTs are not supported (need LUT_3D_SIZE)")
            case "LUT_3D_SIZE": size = Int(parts.count > 1 ? parts[1] : "") ?? 0
            case "DOMAIN_MIN": if let t = triple(Array(parts.dropFirst())) { dmin = t }
            case "DOMAIN_MAX": if let t = triple(Array(parts.dropFirst())) { dmax = t }
            default:
                guard let t = triple(parts) else { continue }
                values += [t.x, t.y, t.z, 1]
            }
        }
        guard size >= 2, size <= 129 else { throw ParseError(message: "Missing or invalid LUT_3D_SIZE") }
        guard values.count == size * size * size * 4 else {
            throw ParseError(message: "Expected \(size * size * size) entries, found \(values.count / 4)")
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(size: size, domainMin: dmin, domainMax: dmax, data: data)
    }

    /// An identity LUT (for tests).
    static func identity(size: Int) -> CubeLUT {
        var v = [Float](); v.reserveCapacity(size * size * size * 4)
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            v += [Float(r) / Float(size - 1), Float(g) / Float(size - 1), Float(b) / Float(size - 1), 1]
        }}}
        return CubeLUT(size: size, domainMin: .zero, domainMax: SIMD3(repeating: 1), data: v.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
