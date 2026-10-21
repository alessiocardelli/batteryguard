import SwiftUI

/// Colori dell'interfaccia. I testi colorati hanno una variante per tema scelta per il contrasto AA sul materiale del popover.
enum Palette {
    // Energia: dal giallo arancio in alto all'arancio rosso in basso. In Display P3 per l'effetto fluo
    // sugli schermi dei Mac; sugli schermi sRGB si riduce da solo ai valori più vicini.
    static let energyTop = Color(.displayP3, red: 1.0, green: 0.7, blue: 0.16)
    static let energyMid = Color(.displayP3, red: 1.0, green: 0.46, blue: 0.0)
    static let energyBottom = Color(.displayP3, red: 1.0, green: 0.28, blue: 0.0)
    static let energyShade = Color(.displayP3, red: 0.62, green: 0.12, blue: 0.0)
    static let energyCore = Color(.displayP3, red: 1.0, green: 0.88, blue: 0.5)

    // Inchiostro scuro sul bottone arancione: il bianco su questi arancioni non arriva a 4.5:1
    static let ink = Color(red: 0.15, green: 0.06, blue: 0.0)

    static func secondaryText(isDark: Bool, highContrast: Bool) -> Color {
        if highContrast { return .primary }
        // Tarati sul caso peggiore del materiale (sfondo chiaro dietro il popover scuro e viceversa)
        return isDark ? Color.white.opacity(0.76) : Color.black.opacity(0.62)
    }

    static func outerEdge(isDark: Bool, highContrast: Bool) -> Color {
        if highContrast { return isDark ? Color.white.opacity(0.7) : Color.black.opacity(0.7) }
        return isDark ? Color.black.opacity(0.6) : Color.black.opacity(0.2)
    }

    static let destructive = Color(red: 0.84, green: 0.0, blue: 0.08)
}
