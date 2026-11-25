// Erzeugt Resources/AppIcon-1024.png: randloses, quadratisches Icon (macOS rundet selbst ab).
// Aufruf: swift Scripts/make-icon.swift Resources/AppIcon-source.png Resources/AppIcon-1024.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Quelle nicht lesbar")
}
// Innenbereich ohne den gemalten Metallrahmen (Quelle: 1254 × 1254)
let scale = CGFloat(cg.width) / 1254
let crop = CGRect(x: 165 * scale, y: 160 * scale, width: 925 * scale, height: 925 * scale).integral
guard let inner = cg.cropping(to: crop) else { fatalError("Crop fehlgeschlagen") }

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.10, blue: 0.12, alpha: 1))   // dunkler Hintergrund des Motivs
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.interpolationQuality = .high
ctx.draw(inner, in: CGRect(x: 0, y: 0, width: size, height: size))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("✅ \(args[2])")
