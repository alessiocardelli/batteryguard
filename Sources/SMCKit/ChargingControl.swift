import Foundation

public enum ChargingControlError: Error, CustomStringConvertible {
    /// Nessuno schema riconosciuto: elenca le chiavi cercate con la loro dimensione, per la diagnosi
    case noChargeKeys(found: String)
    /// Comando valido solo per uno schema diverso da quello del Mac
    case wrongScheme(ChargingScheme)
    /// Il firmware non ha tenuto i valori appena scritti
    case firmwareRejected(read: String)
    /// La chiave dell'alimentatore non ha tenuto il valore appena scritto
    case adapterRejected(key: String, read: String)

    public var description: String {
        switch self {
        case .noChargeKeys(let found): return "no supported charge-control keys (\(found))"
        case .wrongScheme(let scheme): return "not available with the \(scheme.rawValue) scheme"
        case .firmwareRejected(let read): return "firmware did not keep the limit (read back: \(read))"
        case .adapterRejected(let key, let read): return "\(key) did not keep the adapter state (read back: \(read))"
        }
    }
}

public final class ChargingControl {
    public let smc: SMCAccess
    public let scheme: ChargingScheme
    /// Chiave dell'alimentatore, solo con lo schema adapter
    public let adapter: AdapterPower?

    public init(smc: SMCAccess, forceAdapter: Bool = false) throws {
        self.smc = smc
        guard let scheme = ChargingScheme.detect(keySize: smc.dataSize, forceAdapter: forceAdapter) else {
            let found = (ChargingScheme.candidateKeys + AdapterPower.candidates.map(\.key))
                .map { key in smc.dataSize(key).map { "\(key)=\($0)B" } ?? "\(key) absent" }
                .joined(separator: ", ")
            throw ChargingControlError.noChargeKeys(found: found)
        }
        self.scheme = scheme
        adapter = scheme == .adapter ? AdapterPower.select(keySize: smc.dataSize) : nil
    }

    // MARK: Schemi legacy: il servizio accende e spegne la ricarica

    public func isChargingEnabled() throws -> Bool {
        guard let key = scheme.legacyKeys.first else { throw ChargingControlError.wrongScheme(scheme) }
        return try smc.read(key).bytes.allSatisfy { $0 == 0 }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        guard scheme == .chte || scheme == .ch0bc else { throw ChargingControlError.wrongScheme(scheme) }
        let bytes = scheme.legacyBytes(enabled: enabled)
        for key in scheme.legacyKeys {
            try smc.write(key, bytes: bytes)
        }
    }

    // MARK: Schema firmware: il servizio imposta le soglie, il firmware le applica

    public func readFirmwareLimit() throws -> FirmwareLimit? {
        FirmwareLimit.decode(
            activation: try smc.read(FirmwareLimit.activationKey).bytes,
            upper: try smc.read(FirmwareLimit.upperKey).bytes,
            lower: try smc.read(FirmwareLimit.lowerKey).bytes
        )
    }

    /// Riscrive solo se lo stato letto è diverso; restituisce lo stato trovato prima, nil se non è servito scrivere.
    /// Dopo la scrittura rilegge: se il firmware non ha tenuto i valori lo segnala, invece di riprovare alla cieca.
    @discardableResult
    public func ensureFirmwareLimit(upper: Int, lower: Int) throws -> (previous: FirmwareLimit?, changed: Bool) {
        guard scheme == .firmware else { throw ChargingControlError.wrongScheme(scheme) }
        let current = try readFirmwareLimit()
        let writes = FirmwareLimit.writesToActivate(upper: upper, lower: lower, current: current)
        guard !writes.isEmpty else { return (current, false) }
        try apply(writes)
        let after = try readFirmwareLimit()
        guard let after, after.isActive, after.upper == upper, after.lower == lower else {
            throw ChargingControlError.firmwareRejected(read: Self.describe(after))
        }
        return (current, true)
    }

    // MARK: Schema adapter: il servizio stacca e riattacca l'alimentazione dalla presa

    public func isAdapterCut() throws -> Bool {
        guard let adapter else { throw ChargingControlError.wrongScheme(scheme) }
        return AdapterPower.isCut(try smc.read(adapter.key).bytes)
    }

    /// Tentativi di scrittura prima di dichiarare che l'SMC non tiene il valore
    public static let adapterWriteAttempts = 3
    /// Pausa tra scrittura e seconda rilettura, e tra un tentativo e l'altro: una scrittura che l'SMC
    /// annulla dopo un istante deve risultare fallita, non riuscita
    public static let adapterVerifyDelay: TimeInterval = 0.3

    /// Scrive e verifica con due riletture (subito e dopo una pausa), fino a 3 tentativi.
    /// Se l'SMC non tiene il valore lo dice: il ciclo non deve credere a uno stato che il chip non ha.
    public func setAdapterCut(_ cut: Bool) throws {
        guard let adapter else { throw ChargingControlError.wrongScheme(scheme) }
        var read: [UInt8] = []
        for attempt in 1...Self.adapterWriteAttempts {
            if attempt > 1 { smc.pause(Self.adapterVerifyDelay) }
            try smc.write(adapter.key, bytes: [cut ? adapter.cutByte : AdapterPower.attachedByte])
            read = try smc.read(adapter.key).bytes
            guard AdapterPower.isCut(read) == cut else { continue }
            smc.pause(Self.adapterVerifyDelay)
            read = try smc.read(adapter.key).bytes
            if AdapterPower.isCut(read) == cut { return }
        }
        throw ChargingControlError.adapterRejected(key: adapter.key, read: read.map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    /// Riattacca anche se la chiave dice già 00: dal vivo, a coperchio chiuso, il Mac è rimasto a batteria
    /// con CHIE a 00. Restituisce se la chiave era staccata.
    @discardableResult
    public func forceAdapterAttached() throws -> Bool {
        let wasCut = try isAdapterCut()
        try setAdapterCut(false)
        return wasCut
    }

    /// Prima cosa che fa il servizio a ogni avvio e `enable-charging` alla disinstallazione, qualunque sia lo schema:
    /// un servizio morto male (kill -9) può aver lasciato l'alimentazione staccata. Riattacca ogni chiave nota
    /// che risulta staccata e restituisce quelle toccate.
    @discardableResult
    public static func reattachAdapter(smc: SMCAccess) throws -> [String] {
        var reattached: [String] = []
        for candidate in AdapterPower.candidates where smc.dataSize(candidate.key) == 1 {
            guard AdapterPower.isCut(try smc.read(candidate.key).bytes) else { continue }
            try smc.write(candidate.key, bytes: [AdapterPower.attachedByte])
            reattached.append(candidate.key)
        }
        return reattached
    }

    // MARK: Comune

    /// Torna alla ricarica normale: legacy riabilita la ricarica, firmware spegne il limite (bfF0 = 0x00),
    /// adapter riattacca l'alimentazione. Restituisce false se non c'era niente da cambiare (legacy scrive sempre).
    @discardableResult
    public func restoreNormalCharging() throws -> Bool {
        switch scheme {
        case .chte, .ch0bc:
            try setChargingEnabled(true)
            return true
        case .firmware:
            let activation = try smc.read(FirmwareLimit.activationKey).bytes
            let writes = FirmwareLimit.writesToDeactivate(currentActivation: activation.count == 1 ? activation[0] : nil)
            try apply(writes)
            return !writes.isEmpty
        case .adapter:
            guard try isAdapterCut() else { return false }
            try setAdapterCut(false)
            return true
        }
    }

    public static func describe(_ limit: FirmwareLimit?) -> String {
        guard let limit else { return "unreadable" }
        return String(format: "bfF0=0x%02x bfD0=%d bfE0=%d", limit.activation, limit.upper, limit.lower)
    }

    private func apply(_ writes: [SMCWrite]) throws {
        for write in writes {
            try smc.write(write.key, bytes: write.bytes)
        }
    }
}
