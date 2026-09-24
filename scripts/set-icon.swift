// Aplica uma arte de ícone (quadrada, cantos transparentes) ao AppIcon do TokenBar.
// Enquadra no gabarito do macOS (arte de 824 px centrada numa tela de 1024, com sombra) e gera todos os tamanhos.
// Uso, na raiz do projeto: swift scripts/set-icon.swift scripts/icon-source.webp
import AppKit

guard CommandLine.arguments.count > 1,
      let source = NSImage(contentsOf: URL(filePath: CommandLine.arguments[1])) else {
    print("Uso: swift scripts/set-icon.swift <imagem>")
    exit(1)
}

func canvas(_ pixels: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let master = canvas(1024) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 20
    shadow.set()
    // Recorta pela forma do ícone para descartar pixels soltos fora da borda da arte.
    let art = CGRect(x: 100, y: 100, width: 824, height: 824)
    let clipped = NSImage(size: art.size, flipped: false) { rect in
        NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 200, yRadius: 200).addClip()
        source.draw(in: rect)
        return true
    }
    clipped.draw(in: art)
}
try master.representation(using: .png, properties: [:])!.write(to: URL(filePath: "scripts/icon-1024.png"))

let iconSet = "TokenBar/Assets.xcassets/AppIcon.appiconset"
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let resized = canvas(pixels) { master.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels)) }
        try resized.representation(using: .png, properties: [:])!.write(to: URL(filePath: "\(iconSet)/\(name)"))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(filePath: "\(iconSet)/Contents.json"))
print("Ícone aplicado: scripts/icon-1024.png + \(images.count) tamanhos em \(iconSet)")
