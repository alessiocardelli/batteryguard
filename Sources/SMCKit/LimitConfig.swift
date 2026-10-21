import Foundation

/// File della soglia condiviso tra app e servizio.
/// La cartella è di root, il file appartiene all'utente che ha installato: l'app lo riscrive
/// senza password, il servizio lo legge e scarta tutto ciò che non è una soglia valida.
public enum LimitConfig {
    public static let path = "/Library/Application Support/ChargeLimit/config"
    public static let range = 50...100
    public static let defaultLimit = 80

    /// Formato: una riga `limit=NN`. Testo illeggibile o valore fuori range = nil.
    public static func parse(_ text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "limit", let value = Int(parts[1]), range.contains(value) {
                return value
            }
        }
        return nil
    }

    public static func read() -> Int? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func serialize(_ limit: Int) -> String {
        "limit=\(limit)\n"
    }
}
