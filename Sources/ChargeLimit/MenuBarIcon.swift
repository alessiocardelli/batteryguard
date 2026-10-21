import AppKit

/// Glifo template disegnato a mano: batteria parzialmente piena con una tacca alla soglia,
/// diverso dall'indicatore batteria di sistema che sta accanto nella barra dei menu.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 24, height: 12), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: 20, height: 11), xRadius: 3, yRadius: 3)
            body.lineWidth = 1
            body.stroke()

            NSBezierPath(roundedRect: NSRect(x: 21.5, y: 3.5, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()

            // Riempimento fino a circa metà, tacca verticale piena a circa l'80%
            NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 9, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(rect: NSRect(x: 14.5, y: 2.5, width: 1.5, height: 7)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
