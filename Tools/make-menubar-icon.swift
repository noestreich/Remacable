// Macht aus einer beliebigen Vorlage ein Menueleisten-Template-Icon:
// Rand wegschneiden, auf Zielhoehe skalieren, alles Schwarze in reine
// Deckkraft uebersetzen. macOS faerbt Template-Bilder selbst ein — hell auf
// dunkler Menueleiste, dunkel auf heller.
//
//   swift make-menubar-icon.swift <quelle.png> <ziel.png> [hoehe=44]

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("Aufruf: make-menubar-icon.swift <quelle> <ziel> [hoehe]")
    exit(2)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let targetURL = URL(fileURLWithPath: arguments[2])
let targetHeight = arguments.count > 3 ? Int(arguments[3]) ?? 44 : 44

guard let source = NSImage(contentsOf: sourceURL),
      let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("Quelle nicht lesbar: \(sourceURL.path)")
    exit(1)
}

let width = cgImage.width, height = cgImage.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard let readContext = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("Kein Zeichenkontext")
    exit(1)
}
readContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

// Deckkraft je Pixel: echte Transparenz nutzen, sonst Helligkeit umdrehen —
// so funktioniert die Vorlage mit freigestelltem wie mit weissem Hintergrund.
func coverage(x: Int, y: Int) -> UInt8 {
    let offset = (y * width + x) * 4
    let alpha = pixels[offset + 3]
    if alpha < 8 { return 0 }
    let luminance = (Int(pixels[offset]) * 299 + Int(pixels[offset + 1]) * 587
                     + Int(pixels[offset + 2]) * 114) / 1000
    let ink = 255 - min(luminance, 255)
    return UInt8(ink * Int(alpha) / 255)
}

var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where coverage(x: x, y: y) > 24 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else {
    print("Vorlage ist leer")
    exit(1)
}
let cropWidth = maxX - minX + 1, cropHeight = maxY - minY + 1
print("Zuschnitt: \(cropWidth)×\(cropHeight) aus \(width)×\(height)")

// Deckungsmaske in Originalgroesse, danach in einem Rutsch skalieren
var mask = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
for y in 0..<cropHeight {
    for x in 0..<cropWidth {
        let value = coverage(x: minX + x, y: minY + y)
        let offset = (y * cropWidth + x) * 4
        mask[offset] = 0; mask[offset + 1] = 0; mask[offset + 2] = 0
        mask[offset + 3] = value  // premultiplied schwarz: RGB bleibt 0
    }
}
guard let maskContext = CGContext(
    data: &mask, width: cropWidth, height: cropHeight, bitsPerComponent: 8,
    bytesPerRow: cropWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let cropped = maskContext.makeImage() else {
    print("Zuschnitt fehlgeschlagen")
    exit(1)
}

let scale = Double(targetHeight) / Double(cropHeight)
let outWidth = max(1, Int((Double(cropWidth) * scale).rounded()))
guard let outContext = CGContext(
    data: nil, width: outWidth, height: targetHeight, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    print("Kein Ausgabekontext")
    exit(1)
}
outContext.interpolationQuality = .high
outContext.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: targetHeight))

guard let result = outContext.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        targetURL as CFURL, "public.png" as CFString, 1, nil) else {
    print("Ziel nicht beschreibbar")
    exit(1)
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else {
    print("Schreiben fehlgeschlagen")
    exit(1)
}
print("Geschrieben: \(targetURL.path) — \(outWidth)×\(targetHeight)")
