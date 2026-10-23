import Foundation

/// Segnalazione da mandare per email quando BatteryGuard non è disponibile su un Mac.
/// Solo Foundation: si compila da sola nei test (Tests/ReportTests).
struct ReportInfo {
    var appVersion: String
    var osVersion: String
    var osBuild: String
    var model: String
    var chip: String
    /// Schema di ricarica in uso dal servizio (dal battito), nil se il servizio non l'ha scritto
    var mode: String?
    var probe: [String]
    var heartbeat: String?
    var logTail: [String]
}

enum Report {
    static let recipient = "info@alessiocardelli.com"
    /// I client di posta e i browser non garantiscono link mailto più lunghi di circa 2000 caratteri
    static let maxMailtoLength = 2000

    static func subject(appVersion: String) -> String {
        "BatteryGuard report \(appVersion)"
    }

    /// In inglese: è un rapporto tecnico, lo legge chi sviluppa. L'ordine conta: se la mail va accorciata
    /// si tagliano le righe dal fondo, quindi prima i dati del Mac e le chiavi, il log per ultimo.
    static func text(_ info: ReportInfo) -> String {
        var lines = [
            "App: \(info.appVersion)",
            "macOS: \(info.osVersion) (\(info.osBuild))",
            "Model: \(info.model)",
            "Chip: \(info.chip)",
            "Mode: \(info.mode ?? "unknown")",
            "",
            "SMC probe (read-only):"
        ]
        lines += info.probe
        lines += ["", "Service heartbeat:"]
        lines += info.heartbeat.map { $0.split(whereSeparator: \.isNewline).map(String.init) } ?? ["(none)"]
        lines += ["", "Service log (last \(info.logTail.count) lines):"]
        lines += info.logTail.isEmpty ? ["(empty)"] : info.logTail
        return lines.joined(separator: "\n")
    }

    /// Toglie dal testo ciò che identifica la persona: cartella home, nome utente, nome completo, nome del Mac.
    /// Valori sotto i 3 caratteri non si sostituiscono: rovinerebbero il resto del testo senza proteggere niente.
    static func anonymize(_ text: String, home: String, userName: String, fullName: String, computerNames: [String]) -> String {
        var replacements: [(String, String)] = [(home, "~")]
        replacements += computerNames.map { ($0, "<computer>") }
        replacements += [(fullName, "<name>"), (userName, "<user>")]
        var result = text
        for (value, placeholder) in replacements.filter({ $0.0.count >= 3 }).sorted(by: { $0.0.count > $1.0.count }) {
            result = result.replacingOccurrences(of: value, with: placeholder, options: .caseInsensitive)
        }
        // Rete di sicurezza: qualunque percorso dentro /Users perde il nome della cartella
        return result.replacingOccurrences(of: "/Users/[^/\\s]+", with: "/Users/<user>", options: .regularExpression)
    }

    /// Link mailto con oggetto e corpo. Se il rapporto non ci sta, il corpo è la nota `clipboardNote`
    /// seguita dall'inizio del rapporto, e `isTruncated` dice al chiamante di copiare il rapporto completo negli appunti.
    static func mailURL(subject: String, body: String, clipboardNote: String, maxLength: Int = maxMailtoLength) -> (url: URL, isTruncated: Bool) {
        let full = mailto(subject: subject, body: body)
        if full.count <= maxLength { return (URL(string: full)!, false) }

        var lines = body.components(separatedBy: "\n")
        while !lines.isEmpty {
            lines.removeLast()
            let candidate = mailto(subject: subject, body: clipboardNote + "\n\n" + lines.joined(separator: "\n") + "\n…")
            if candidate.count <= maxLength { return (URL(string: candidate)!, true) }
        }
        return (URL(string: mailto(subject: subject, body: clipboardNote))!, true)
    }

    private static func mailto(subject: String, body: String) -> String {
        "mailto:\(recipient)?subject=\(encode(subject))&body=\(encode(body))"
    }

    /// Solo i caratteri non riservati restano in chiaro: spazi, a capo, & e = vanno codificati nel corpo
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
