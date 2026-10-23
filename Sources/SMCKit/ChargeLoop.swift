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
    /// Modalità adapter: sotto questa carica l'alimentazione si riattacca sempre, qualunque sia la soglia
    public static let adapterSafetyFloor = 20
    /// Modalità adapter: batteria illeggibile per tanti cicli di fila = alimentazione riattaccata e non disponibile.
    /// Più severo degli altri schemi: senza leggere la carica il Mac potrebbe scaricarsi a cavo inserito
    public static let adapterMaxBatteryReadFailures = 3
    /// Modalità adapter: dopo la riapertura del coperchio, lo scollegamento del monitor esterno o il risveglio niente distacco per 30 secondi,
    /// così aperture e chiusure ravvicinate non trovano mai l'alimentatore staccato
    public static let adapterHoldAfterLidOpen: TimeInterval = 30

    public let control: ChargingControl
    public private(set) var lastError: ServiceError?
    public private(set) var isUnavailable = false

    private let log: (String) -> Void
    private var consecutiveFailures = 0
    private var firmwareRetryAfter: Date?
    private var firmwareRejections = 0
    /// Ultimo limite firmware scritto da noi: se lo ritroviamo diverso l'ha cambiato qualcun altro (anche macOS)
    private var appliedFirmwareLimit: (upper: Int, lower: Int)?
    private var batteryReadFailures = 0
    /// Tra la notifica di sonno e il risveglio l'alimentazione non si stacca: il servizio non può sorvegliare
    public private(set) var isSleeping = false
    /// Modalità adapter: stato dell'alimentazione riletto dal chip ora (true = staccata), nil con gli altri schemi
    /// o se la chiave non si legge. Mai una copia in memoria: il battito deve dire quello che c'è davvero
    public var isAdapterCut: Bool? {
        guard control.scheme == .adapter else { return nil }
        return try? control.isAdapterCut()
    }
    /// Coperchio appena riaperto o Mac appena sveglio: il primo ciclo fissa la fine dell'attesa
    private var holdPending = false
    private var noCutUntil: Date?
    /// La riscrittura a coperchio chiuso con il Mac a batteria va nel log una volta per chiusura
    private var stuckOnBatteryLogged = false
    /// Con il coperchio chiuso l'alimentazione non si stacca mai: un MacBook chiuso con monitor esterno
    /// che va a batteria per macOS è un Mac da mettere in stop
    public private(set) var isLidClosed = false
    /// Con un monitor esterno l'alimentazione non si stacca mai, anche a coperchio aperto: chi chiude il MacBook ha
    /// sempre un monitor, e dal vivo dopo il riattacco a coperchio chiuso macOS è rimasto a batteria per 2 minuti
    /// ed è andato in stop. Sui Mac desktop, che un monitor ce l'hanno sempre, la modalità in pratica non stacca mai
    public private(set) var isExternalDisplayConnected = false

    public init(control: ChargingControl, log: @escaping (String) -> Void) {
        self.control = control
        self.log = log
    }

    public var state: ServiceStatus.State { isUnavailable ? .failed : .running }

    /// `lidClosed` ed `externalDisplay`: letture a ogni ciclo, riserva delle notifiche (lidClosed nil = Mac senza coperchio)
    public func tick(battery: BatteryStatus?, limit: Int, now: Date, lidClosed: Bool? = nil, externalDisplay: Bool = false) {
        guard !isUnavailable else { return }
        lidChanged(closed: lidClosed ?? false)
        displayChanged(connected: externalDisplay)
        switch control.scheme {
        case .firmware: firmwareTick(limit: limit, now: now)
        case .adapter: adapterTick(battery: battery, limit: limit, now: now)
        case .chte, .ch0bc: legacyTick(battery: battery, limit: limit)
        }
    }

    /// Notifica di sistema prima del sonno: nessuna garanzia che l'SMC tenga l'alimentazione staccata
    /// mentre il servizio è fermo, quindi la si riattacca sempre (la carica può salire durante il sonno).
    public func systemWillSleep() {
        isSleeping = true
        guard control.scheme == .adapter, !isUnavailable else { return }
        attachForSafety("sonno in arrivo")
    }

    /// Notifica di chiusura del coperchio: si riattacca subito, prima che macOS decida lo stop
    public func lidChanged(closed: Bool) {
        guard closed != isLidClosed else { return }
        isLidClosed = closed
        guard control.scheme == .adapter, !isUnavailable else { return }
        guard closed else {
            holdPending = true
            return log("coperchio aperto: niente distacco per \(Int(Self.adapterHoldAfterLidOpen)) secondi")
        }
        stuckOnBatteryLogged = false
        attachForSafety("coperchio chiuso")
    }

    /// Notifica di collegamento o scollegamento di un monitor esterno: collegato si riattacca subito
    public func displayChanged(connected: Bool) {
        guard connected != isExternalDisplayConnected else { return }
        isExternalDisplayConnected = connected
        guard control.scheme == .adapter, !isUnavailable else { return }
        guard connected else {
            holdPending = true
            return log("monitor esterno scollegato: niente distacco per \(Int(Self.adapterHoldAfterLidOpen)) secondi")
        }
        attachForSafety("monitor esterno collegato")
    }

    public func systemDidWake() {
        isSleeping = false
        holdPending = true
    }

    /// Coperchio chiuso, monitor esterno e sonno: si scrive 00 anche se la chiave lo dice già (dal vivo il Mac è rimasto a batteria
    /// con CHIE a 00) e si verifica. Se l'SMC non tiene il valore il limite si ferma e torna la ricarica normale
    private func attachForSafety(_ event: String) {
        do {
            let wasCut = try control.forceAdapterAttached()
            log(wasCut ? "\(event): alimentatore riattaccato" : "\(event): alimentatore già collegato, 00 riscritto")
        } catch {
            giveUp(.smcFailed, "\(event): \(error)")
        }
    }

    /// Senza notifiche di sonno la modalità adapter non è sicura: il Mac potrebbe dormire a batteria col cavo inserito
    public func giveUpWithoutSleepNotifications() {
        giveUp(.sleepNotificationsUnavailable, "IORegisterForSystemPower failed")
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

    /// Stessa isteresi degli schemi legacy, ma sopra la soglia il Mac va a batteria invece di restare fermo.
    /// Si stacca solo con il cavo inserito, coperchio aperto e nessun monitor esterno, mai in vista del sonno; si riattacca sotto soglia meno isteresi
    /// e comunque sotto il 20%.
    private func adapterTick(battery: BatteryStatus?, limit: Int, now: Date) {
        guard let battery else {
            batteryReadFailures += 1
            if batteryReadFailures >= Self.adapterMaxBatteryReadFailures {
                return giveUp(.batteryUnreadable, "IOPowerSources returned no battery \(batteryReadFailures) times")
            }
            return failure(.batteryUnreadable, "IOPowerSources returned no battery")
        }
        batteryReadFailures = 0
        if holdPending {
            noCutUntil = now.addingTimeInterval(Self.adapterHoldAfterLidOpen)
            holdPending = false
        }
        let holding = noCutUntil.map { now < $0 } ?? false
        do {
            let cut = try control.isAdapterCut()
            if cut, let reason = reattachReason(percent: battery.percent, limit: limit) {
                try control.setAdapterCut(false)
                log("\(reason): alimentatore riattaccato")
            } else if !cut && isLidClosed && !battery.externalConnected {
                try control.setAdapterCut(false)
                if !stuckOnBatteryLogged { log("coperchio chiuso ma Mac a batteria con \(control.adapter?.key ?? "la chiave") a 00: 00 riscritto") }
                stuckOnBatteryLogged = true
            } else if !cut && !isSleeping && !isLidClosed && !isExternalDisplayConnected && !holding && battery.externalConnected && battery.percent >= limit {
                try control.setAdapterCut(true)
                log("batteria \(battery.percent)% >= \(limit)%: alimentatore staccato, il Mac va a batteria")
            }
            success()
        } catch let error as ChargingControlError {
            // L'SMC non tiene il valore nemmeno al terzo tentativo: non si continua a sperare
            giveUp(.smcFailed, "\(error)")
        } catch {
            failure(.smcFailed, "\(error)")
        }
    }

    private func reattachReason(percent: Int, limit: Int) -> String? {
        if percent < Self.adapterSafetyFloor { return "batteria \(percent)% sotto il \(Self.adapterSafetyFloor)%" }
        if isSleeping { return "sonno in corso" }
        if isLidClosed { return "coperchio chiuso" }
        if isExternalDisplayConnected { return "monitor esterno collegato" }
        if percent <= limit - Self.hysteresis { return "batteria \(percent)% <= \(limit - Self.hysteresis)%" }
        return nil
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

    /// Una ricarica lasciata bloccata (CHTE a 01), un limite firmware a metà o l'alimentatore staccato
    /// non devono restare attivi
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
