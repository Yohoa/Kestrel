import AppKit
import CoreImage

// Builds the app icon from a public-domain wood engraving:
//   William Yarrell, "A History of British Birds", vol. 1 (London: John Van Voorst, 1843), p. 52,
//   "The Kestrel, or Windhover". Scan: Internet Archive item historyofbritish01yarr_0
//   (University of Toronto, Fisher Library), https://archive.org/details/historyofbritish01yarr_0
// The engraving is cropped to the perched bird, its paper is cleaned to white, and it is printed (multiply)
// onto a cream squircle. Usage: make_icon <source.jpg> <crop x y size> <out.png> <black> <white>

let a = CommandLine.arguments
let src = CIImage(contentsOf: URL(fileURLWithPath: a[1]))!
let (cx, cy, cs) = (CGFloat(Double(a[2])!), CGFloat(Double(a[3])!), CGFloat(Double(a[4])!))
let H = src.extent.height
// crop (top-left coordinates in, Core Image is bottom-left)
var ink = src.cropped(to: CGRect(x: cx, y: H - cy - cs, width: cs, height: cs))
    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.0])
// levels: the page's ochre paper → white, the ink → near-black
let lo = CGFloat(Double(a[6])!), hi = CGFloat(Double(a[7])!)      // black / white points (0…1)
let k = 1 / (hi - lo)
ink = ink.applyingFilter("CIColorMatrix", parameters: [
    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
    "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputBiasVector": CIVector(x: -lo * k, y: -lo * k, z: -lo * k, w: 0)])
    .applyingFilter("CIColorClamp")
let ctx = CIContext()
let inkCG = ctx.createCGImage(ink, from: ink.extent)!

let S = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let g = NSGraphicsContext.current!.cgContext
let box = CGRect(x: 62, y: 62, width: 900, height: 900)            // macOS icon grid: 100 px margin at 1024
let squircle = CGPath(roundedRect: box, cornerWidth: 200, cornerHeight: 200, transform: nil)
g.addPath(squircle); g.clip()
let paper = NSGradient(colors: [NSColor(red: 0.985, green: 0.965, blue: 0.92, alpha: 1), NSColor(red: 0.925, green: 0.885, blue: 0.79, alpha: 1)])!
paper.draw(in: box, angle: -90)
g.setBlendMode(.multiply)
g.interpolationQuality = .high
g.draw(inkCG, in: box)
g.setBlendMode(.normal)
g.resetClip()
g.addPath(squircle)
g.setStrokeColor(NSColor(white: 0.1, alpha: 0.22).cgColor); g.setLineWidth(3); g.strokePath()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[5]))
