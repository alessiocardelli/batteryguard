import Foundation

/// Ciclo di controllo del servizio, senza file né timer: il servizio lo chiama ogni 5 secondi,
/// i test lo fanno girare sul finto SMC.
/// Quando il limite non può funzionare (errori che si ripetono, firmware che rifiuta i valori anche al
/// secondo tentativo) il ciclo si ferma per sempre, rimette la ricarica normale e il battito dice `failed`:
/// l'app mostra lo stato unico "non disponibile". Riparte solo con un nuovo avvio del servizio.
public final class ChargeLoop {
    public static let hysteresis = 2
    /// Se il firmware rifiuta le soglie si riprova una volta sola dopo questa pausa, non a ogni ciclo
    public static let firmwareRetryDelay: TimeInterval = 60
    /// Cicli consecutivi con errore prima di arrendersi: assorbe un intoppo passeggero (es. al risveglio)
    public static let maxConsecutiveFailures = 5

    public let control: ChargingControl
    public private(set) var lastError: ServiceError?
    public private(set) var isUnavailable = false

    private let log: (String) -> Void
    private var consecutiveFailures = 0
    private var firmwareRetryAfter: Date?
    private var firmwareRejections = 0
    /// Ultimo limite firmware scritto da noi: se lo ritroviamo diverso l'ha cambiato qualcun altro (anche macOS)
    private var appliedFirmwareLimit: (upper: Int, lower: Int)?

    public init(control: ChargingControl, log: @escaping (String) -> Void) {
        self.control = control
        self.log = log
    }

    public var state: ServiceStatus.State { isUnavailable ? .failed : .running }

    public func tick(battery: BatteryStatus?, limit: Int, now: Date) {
        guard !isUnavailable else { return }
        if control.scheme == .firmware {
            firmwareTick(limit: limit, now: now)
        } else {
            legacyTick(battery: battery, limit: limit)
        }
    }

    private func legacyTick(battery: BatteryStatus?, limit: Int) {
        guard let battery else { return failure(.batteryUnreadable, "IOPowerSources returned no battery") }
        do {
            let enabled = try control.isChargingEnabled()
            if limit >= 100 {
                if !enabled {
                    try control.setChargingEnabled(true)
                    log("soglia 100%: ricarica riabilitata")
                }
            } else if enabled && battery.percent >= limit {
                try control.setChargingEnabled(false)
                log("batteria \(battery.percent)% >= \(limit)%: ricarica bloccata")
            } else if !enabled && battery.percent <= limit - Self.hysteresis {
                try control.setChargingEnabled(true)
                log("batteria \(battery.percent)% <= \(limit - Self.hysteresis)%: ricarica ripresa")
            }
            success()
        } catch {
            failure(.smcFailed, "\(error)")
        }
    }

    /// Il firmware tiene la carica tra lower e upper anche quando il servizio non gira (sonno compreso):
    /// qui si controlla soltanto che le soglie siano ancora quelle giuste.
    private func firmwareTick(limit: Int, now: Date) {
        if let retry = firmwareRetryAfter, now < retry { return }
        firmwareRetryAfter = nil
        do {
            if limit >= 100 {
                if try control.restoreNormalCharging() { log("soglia 100%: limite firmware disattivato") }
                appliedFirmwareLimit = nil
                return success()
            }
            let target = (upper: limit, lower: limit - Self.hysteresis)
            let result = try control.ensureFirmwareLimit(upper: target.upper, lower: target.lower)
            firmwareRejections = 0
            success()
            guard result.changed else { return }
            let previous = ChargingControl.describe(result.previous)
            if let applied = appliedFirmwareLimit, applied == target {
                log("limite firmware cambiato da fuori (\(previous)): ripristinato \(target.lower)-\(target.upper)%")
            } else {
                log("limite firmware impostato: \(target.lower)-\(target.upper)% (prima: \(previous))")
            }
            appliedFirmwareLimit = target
        } catch ChargingControlError.firmwareRejected(let read) {
            firmwareRejections += 1
            let detail = "\(ChargingControlError.firmwareRejected(read: read))"
            if firmwareRejections >= 2 { return giveUp(.firmwareRejected, detail) }
            recordError(.firmwareRejected, detail)
            firmwareRetryAfter = now.addingTimeInterval(Self.firmwareRetryDelay)
        } catch {
            failure(.smcFailed, "\(error)")
        }
    }

    private func success() {
        consecutiveFailures = 0
        if lastError != nil { log("di nuovo funzionante") }
        lastError = nil
    }

    private func failure(_ code: ServiceErrorCode, _ detail: String) {
        recordError(code, detail)
        consecutiveFailures += 1
        if consecutiveFailures >= Self.maxConsecutiveFailures { giveUp(code, detail) }
    }

    /// Lo stesso errore a ogni ciclo va nel log una volta sola
    private func recordError(_ code: ServiceErrorCode, _ detail: String) {
        let error = ServiceError(code, detail: detail)
        if error != lastError { log("errore \(code.rawValue): \(detail)") }
        lastError = error
    }

    /// Una ricarica lasciata bloccata (CHTE a 01) o un limite firmware a metà non devono restare attivi
    private func giveUp(_ code: ServiceErrorCode, _ detail: String) {
        recordError(code, detail)
        isUnavailable = true
        do {
            try control.restoreNormalCharging()
            log("limite non disponibile su questo Mac: ricarica normale ripristinata")
        } catch {
            log("limite non disponibile su questo Mac; ripristino della ricarica normale non riuscito: \(error)")
        }
    }
}
