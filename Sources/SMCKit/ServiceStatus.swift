import Foundation

/// Codici d'errore stabili scritti dal servizio nel battito: servono alla diagnosi e finiscono nella segnalazione.
public enum ServiceErrorCode: String {
    /// Nessuno schema di controllo della ricarica riconosciuto su questo Mac
    case noChargeKeys = "no_charge_keys"
    /// SMC non apribile
    case smcUnavailable = "smc_unavailable"
    /// Lettura o scrittura SMC non riuscita durante il ciclo
    case smcFailed = "smc_failed"
    /// Il firmware non ha tenuto le soglie appena scritte
    case firmwareRejected = "firmware_rejected"
    case batteryUnreadable = "battery_unreadable"
    /// Modalità adapter senza notifiche di sonno: non si può riattaccare l'alimentatore prima del sonno
    case sleepNotificationsUnavailable = "sleep_notifications_unavailable"
}

/// Errore riportato nel battito: `code` è stabile, `detail` è per la diagnosi.
/// Un servizio 1.0.3 scrive solo una frase in `error`: arriva qui come codice sconosciuto.
public struct ServiceError: Equatable {
    public var code: String
    public var detail: String?

    public init(code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public init(_ code: ServiceErrorCode, detail: String? = nil) {
        self.init(code: code.rawValue, detail: detail)
    }

    public var knownCode: ServiceErrorCode? { ServiceErrorCode(rawValue: code) }
}

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
    public var error: ServiceError?
    /// Solo con lo schema adapter: true = alimentazione dalla presa staccata, il Mac va a batteria
    public var adapterCut: Bool?
    /// Coperchio letto dal servizio (AppleClamshellState), nil sui Mac senza coperchio
    public var lidClosed: Bool?

    public init(updated: Date, state: State, scheme: String? = nil, error: ServiceError? = nil, adapterCut: Bool? = nil, lidClosed: Bool? = nil) {
        self.updated = updated
        self.state = state
        self.scheme = scheme
        self.error = error
        self.adapterCut = adapterCut
        self.lidClosed = lidClosed
    }

    /// Formato: righe `chiave=valore` (updated, state, scheme, adapter, lid, error, detail). Senza `updated` o `state` validi il battito non conta.
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
                             scheme: fields["scheme"],
                             error: fields["error"].map { ServiceError(code: $0, detail: fields["detail"]) },
                             adapterCut: fields["adapter"].flatMap { ["cut": true, "attached": false][$0] },
                             lidClosed: fields["lid"].flatMap { ["closed": true, "open": false][$0] })
    }

    public func serialize() -> String {
        var text = "updated=\(Int(updated.timeIntervalSince1970))\nstate=\(state.rawValue)\n"
        if let scheme { text += "scheme=\(Self.singleLine(scheme))\n" }
        if let adapterCut { text += "adapter=\(adapterCut ? "cut" : "attached")\n" }
        if let lidClosed { text += "lid=\(lidClosed ? "closed" : "open")\n" }
        if let error {
            text += "error=\(Self.singleLine(error.code))\n"
            if let detail = error.detail { text += "detail=\(Self.singleLine(detail))\n" }
        }
        return text
    }

    /// In valore assoluto: se l'orologio torna indietro il battito resta valido, il servizio lo riallinea al ciclo dopo.
    public func isFresh(at now: Date) -> Bool {
        abs(now.timeIntervalSince(updated)) < Self.maxAge
    }

    /// Il pannello mostra "A batteria" solo se un battito recente dice che è il servizio ad aver staccato l'alimentatore.
    /// "adapter" è il rawValue di ChargingScheme.adapter: questo file si compila da solo nei test
    public func isOnBatteryByAdapterCut(at now: Date) -> Bool {
        isFresh(at: now) && state == .running && scheme == "adapter" && adapterCut == true
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
    /// Il servizio stesso dice che il limite non può funzionare su questo Mac (battito recente `failed`)
    case failed
    /// Installato (plist e binario ci sono) ma né il battito né launchd dicono che lavora: l'app ricontrolla
    /// una volta prima di darlo per non disponibile, launchd potrebbe star rilanciando il servizio
    case notResponding

    /// Il battito recente ha la precedenza; launchd è solo un segnale in più, utile anche con un servizio
    /// di una versione precedente che il battito non lo scrive.
    public static func evaluate(filesPresent: Bool, status: ServiceStatus?, launchdRunning: Bool, now: Date) -> ServiceHealth {
        guard filesPresent else { return .notInstalled }
        if let status, status.isFresh(at: now) {
            switch status.state {
            case .running: return .running
            case .failed: return .failed
            case .stopped: return .notResponding
            }
        }
        return launchdRunning ? .running : .notResponding
    }
}

