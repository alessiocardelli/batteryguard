import Foundation

public enum ChargingControlError: Error, CustomStringConvertible {
    /// Nessuno schema riconosciuto: elenca le chiavi cercate con la loro dimensione, per la diagnosi
    case noChargeKeys(found: String)
    /// Comando valido solo per uno schema diverso da quello del Mac
    case wrongScheme(ChargingScheme)
    /// Il firmware non ha tenuto i valori appena scritti
    case firmwareRejected(read: String)

    public var description: String {
        switch self {
        case .noChargeKeys(let found): return "no supported charge-control keys (\(found))"
        case .wrongScheme(let scheme): return "not available with the \(scheme.rawValue) scheme"
        case .firmwareRejected(let read): return "firmware did not keep the limit (read back: \(read))"
        }
    }
}

public final class ChargingControl {
    public let smc: SMCAccess
    public let scheme: ChargingScheme

    public init(smc: SMCAccess) throws {
        self.smc = smc
        guard let scheme = ChargingScheme.detect(keySize: smc.dataSize) else {
            let found = ChargingScheme.candidateKeys
                .map { key in smc.dataSize(key).map { "\(key)=\($0)B" } ?? "\(key) absent" }
                .joined(separator: ", ")
            throw ChargingControlError.noChargeKeys(found: found)
        }
        self.scheme = scheme
    }

    // MARK: Schemi legacy: il servizio accende e spegne la ricarica

    public func isChargingEnabled() throws -> Bool {
        guard let key = scheme.legacyKeys.first else { throw ChargingControlError.wrongScheme(scheme) }
        return try smc.read(key).bytes.allSatisfy { $0 == 0 }
    }

    public func setChargingEnabled(_ enabled: Bool) throws {
        guard scheme != .firmware else { throw ChargingControlError.wrongScheme(scheme) }
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

    // MARK: Comune

    /// Torna alla ricarica normale: legacy riabilita la ricarica, firmware spegne il limite (bfF0 = 0x00).
    /// Restituisce false se non c'era niente da cambiare (solo firmware, legacy scrive sempre).
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
