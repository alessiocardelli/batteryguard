import Foundation

/// Battito del servizio: il servizio root lo riscrive a ogni ciclo, l'app lo legge per sapere se è vivo.
/// Serve perché `launchctl print` non è un'interfaccia stabile (il formato cambia tra versioni di macOS)
/// e da solo non basta a dire se il servizio sta lavorando.
public struct ServiceStatus: Equatable {
    public enum State: String {
        case running
        /// Il servizio non è riuscito a partire (es. nessuna chiave SMC compatibile) ed è uscito
        case failed
        /// Uscita pulita su segnale (disattivazione, reinstallazione)
        case stopped
    }

    public static let path = "/Library/Application Support/BatteryGuard/status"
    /// Il servizio scrive ogni 5 secondi: oltre questa età il battito è fermo.
    public static let maxAge: TimeInterval = 30

    public var updated: Date
    public var state: State
    public var scheme: String?
    public var error: String?

    public init(updated: Date, state: State, scheme: String? = nil, error: String? = nil) {
        self.updated = updated
        self.state = state
        self.scheme = scheme
        self.error = error
    }

    /// Formato: righe `chiave=valore`. Senza `updated` o `state` validi il battito non conta.
    public static func parse(_ text: String) -> ServiceStatus? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            fields[parts[0].trimmingCharacters(in: .whitespaces)] = value.isEmpty ? nil : value
        }
        guard let seconds = fields["updated"].flatMap(TimeInterval.init), seconds.isFinite,
              let state = fields["state"].flatMap(State.init) else { return nil }
        return ServiceStatus(updated: Date(timeIntervalSince1970: seconds), state: state,
                             scheme: fields["scheme"], error: fields["error"])
    }

    public func serialize() -> String {
        var text = "updated=\(Int(updated.timeIntervalSince1970))\nstate=\(state.rawValue)\n"
        if let scheme { text += "scheme=\(Self.singleLine(scheme))\n" }
        if let error { text += "error=\(Self.singleLine(error))\n" }
        return text
    }

    /// In valore assoluto: se l'orologio torna indietro il battito resta valido, il servizio lo riallinea al ciclo dopo.
    public func isFresh(at now: Date) -> Bool {
        abs(now.timeIntervalSince(updated)) < Self.maxAge
    }

    public static func read(from path: String = path) -> ServiceStatus? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text)
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}

/// Stato del servizio come lo vede l'app.
public enum ServiceHealth: Equatable {
    case notInstalled
    case running
    /// Installato (plist e binario ci sono) ma né il battito né launchd dicono che lavora
    case notResponding(lastError: String?)

    /// Il battito recente ha la precedenza; launchd è solo un segnale in più, utile anche con un servizio
    /// di una versione precedente che il battito non lo scrive.
    public static func evaluate(filesPresent: Bool, status: ServiceStatus?, launchdRunning: Bool, now: Date) -> ServiceHealth {
        guard filesPresent else { return .notInstalled }
        if let status, status.isFresh(at: now) {
            return status.state == .running ? .running : .notResponding(lastError: status.error)
        }
        if launchdRunning { return .running }
        return .notResponding(lastError: status?.error)
    }
}
