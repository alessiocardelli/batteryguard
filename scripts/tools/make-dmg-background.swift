import AppKit

// Sfondo della finestra del dmg: scuro, bagliore arancione dietro l'app, freccia verso Applicazioni.
// Le posizioni delle icone devono coincidere con quelle di scripts/dmg-settings.py.
// uso: make-dmg-background <uscita senza estensione>   -> <uscita>.png e <uscita>@2x.png
let size = CGSize(width: 640, height: 400)
let appCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 470, y: 190)

let energyTop = NSColor(displayP3Red: 1.0, green: 0.7, blue: 0.16, alpha: 1)
let energyMid = NSColor(displayP3Red: 1.0, green: 0.46, blue: 0.0, alpha: 1)

func render(scale: CGFloat, to path: String) {
    let width = Int(size.width * scale), height = Int(size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Coordinate dall'alto, come quelle di Finder
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)

    // Fondo: carbone caldo, più scuro ai bordi
    let base = NSGradient(colors: [NSColor(srgbRed: 0.105, green: 0.095, blue: 0.09, alpha: 1),
                                   NSColor(srgbRed: 0.045, green: 0.043, blue: 0.045, alpha: 1)])!
    base.draw(fromCenter: CGPoint(x: size.width / 2, y: size.height * 0.45), radius: 0,
              toCenter: CGPoint(x: size.width / 2, y: size.height * 0.45), radius: size.width * 0.62, options: [])

    // Bagliore arancione dietro l'app, come la luce della batteria nell'icona
    let glow = NSGradient(colors: [energyMid.withAlphaComponent(0.42), energyMid.withAlphaComponent(0.12), energyMid.withAlphaComponent(0)],
                          atLocations: [0, 0.45, 1], colorSpace: .displayP3)!
    glow.draw(fromCenter: CGPoint(x: appCenter.x, y: appCenter.y + 18), radius: 0,
              toCenter: CGPoint(x: appCenter.x, y: appCenter.y + 18), radius: 170, options: [])
    // Riflesso più debole dietro Applicazioni: la destinazione resta nello stesso mondo
    let faint = NSGradient(colors: [NSColor.white.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0)])!
    faint.draw(fromCenter: applicationsCenter, radius: 0, toCenter: applicationsCenter, radius: 130, options: [])

    // Freccia: filo che si accende verso destra, punta a chevron
    let arrowY = appCenter.y - 6
    let startX = appCenter.x + 92, endX = applicationsCenter.x - 92
    let line = CGMutablePath()
    line.move(to: CGPoint(x: startX, y: arrowY))
    line.addLine(to: CGPoint(x: endX, y: arrowY))
    line.move(to: CGPoint(x: endX - 9, y: arrowY - 8))
    line.addLine(to: CGPoint(x: endX + 0.5, y: arrowY))
    line.addLine(to: CGPoint(x: endX - 9, y: arrowY + 8))
    cg.saveGState()
    cg.addPath(line)
    cg.setLineWidth(2)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.replacePathWithStrokedPath()
    cg.clip()
    let stroke = NSGradient(colors: [energyMid.withAlphaComponent(0.25), energyTop, NSColor(white: 1, alpha: 0.95)],
                            atLocations: [0, 0.55, 1], colorSpace: .displayP3)!
    stroke.draw(from: CGPoint(x: startX, y: arrowY), to: CGPoint(x: endX, y: arrowY), options: [])
    cg.restoreGState()

    // Lastrine di vetro sotto i nomi delle icone. Finder scrive i nomi in nero col tema chiaro e in bianco
    // con quello scuro, e non si può cambiare: un grigio medio (luminanza ~0,18) regge 4,5:1 con entrambi.
    let labelCenterY = appCenter.y + 83
    for center in [appCenter, applicationsCenter] {
        let plate = CGRect(x: center.x - 58, y: labelCenterY - 11, width: 116, height: 22)
        let path = CGPath(roundedRect: plate, cornerWidth: 11, cornerHeight: 11, transform: nil)
        cg.addPath(path)
        cg.setFillColor(CGColor(srgbRed: 0.478, green: 0.459, blue: 0.443, alpha: 1))
        cg.fillPath()
        // Filo di luce in alto, come il bordo del vetro della batteria
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        cg.addPath(CGPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10.5, cornerHeight: 10.5, transform: nil))
        cg.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        cg.setLineWidth(1)
        cg.strokePath()
        cg.restoreGState()
    }

    // Didascalia sotto la freccia: in inglese, lingua di riserva dell'app, perché il dmg ha un solo sfondo
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let caption = NSAttributedString(string: "Drag to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(white: 1, alpha: 0.72),
        .paragraphStyle: paragraph,
        .kern: 0.2
    ])
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    caption.draw(in: CGRect(x: startX - 20, y: arrowY + 14, width: endX - startX + 40, height: 18))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let output = CommandLine.arguments[1]
render(scale: 1, to: output + ".png")
render(scale: 2, to: output + "@2x.png")
