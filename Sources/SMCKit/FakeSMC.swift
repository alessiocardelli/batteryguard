import Foundation

/// Profilo di un Mac per il finto SMC: chiavi con tipo e byte, più una batteria simulata.
/// I profili stanno in Tests/fixtures/smc-profiles (README lì dice da dove viene ognuno).
public struct FakeSMCProfile: Decodable {
    public struct Key: Decodable {
        public var type: String?
        /// Byte esadecimali separati da spazi; stringa vuota = chiave a dimensione zero (segnaposto)
        public var bytes: String?
        /// Codice IOKit restituito da ogni operazione sulla chiave, es. "0xe00002c1" (kIOReturnNotPrivileged)
        public var error: String?
    }

    public struct BatteryModel: Decodable {
        public var percent: Double
        public var pluggedIn: Bool
        public var chargePerMinute: Double
        public var drainPerMinute: Double
    }

    public var name: String
    public var keys: [String: Key]
    public var battery: BatteryModel
    /// Il firmware accetta le scritture su bfD0/bfE0 ma non le tiene
    public var rejectsFirmwareLimit: Bool?
    /// Coperchio simulato (AppleClamshellState): assente = Mac senza coperchio, il servizio legge quello vero
    public var lidClosed: Bool?

    public static func load(from path: String) throws -> FakeSMCProfile {
        try JSONDecoder().decode(FakeSMCProfile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

public enum FakeSMCError: Error, CustomStringConvertible {
    case badBytes(key: String, value: String)
    case badErrorCode(key: String, value: String)

    public var description: String {
        switch self {
        case .badBytes(let key, let value): return "profile key \(key): bytes not hex (\(value))"
        case .badErrorCode(let key, let value): return "profile key \(key): error not a hex code (\(value))"
        }
    }
}

/// SMC finto per i test e per provare il servizio dove non c'è batteria (macchine virtuali).
/// Simula anche la fisica che ci interessa: con la ricarica bloccata (CHTE, CH0B/CH0C) la carica non sale,
/// con il limite firmware attivo (bfF0 = 02) la carica resta tra bfE0 e bfD0, con l'alimentazione staccata
/// (CHIE, CH0I, CH0J diversi da 00) il Mac va a batteria anche col cavo inserito, e nel tempo la carica sale o scende.
public final class FakeSMC: SMCAccess {
    private struct Entry {
        var type: String
        var bytes: [UInt8]
        var errorCode: kern_return_t?
    }

    private var entries: [String: Entry] = [:]
    public var percent: Double
    public var pluggedIn: Bool
    public var rejectsFirmwareLimit: Bool
    /// Il coperchio non tocca la fisica simulata: decide solo il servizio
    public var lidClosed: Bool?
    private let chargePerMinute: Double
    private let drainPerMinute: Double
    /// Il firmware ha raggiunto la soglia superiore e tiene ferma la carica finché non scende all'inferiore
    private var firmwareHolding = false
    public private(set) var writes: [SMCWrite] = []

    public init(profile: FakeSMCProfile) throws {
        for (key, spec) in profile.keys {
            var errorCode: kern_return_t?
            if let error = spec.error {
                let digits = error.hasPrefix("0x") ? String(error.dropFirst(2)) : error
                guard let raw = UInt32(digits, radix: 16) else { throw FakeSMCError.badErrorCode(key: key, value: error) }
                errorCode = kern_return_t(bitPattern: raw)
            }
            let text = spec.bytes ?? ""
            let bytes = try text.split(separator: " ").map { part -> UInt8 in
                guard let byte = UInt8(part, radix: 16) else { throw FakeSMCError.badBytes(key: key, value: text) }
                return byte
            }
            entries[key] = Entry(type: spec.type ?? "hex_", bytes: bytes, errorCode: errorCode)
        }
        percent = profile.battery.percent
        pluggedIn = profile.battery.pluggedIn
        chargePerMinute = profile.battery.chargePerMinute
        drainPerMinute = profile.battery.drainPerMinute
        rejectsFirmwareLimit = profile.rejectsFirmwareLimit ?? false
        lidClosed = profile.lidClosed
        syncBatteryKey()
    }

    public convenience init(profileAt path: String) throws {
        try self.init(profile: FakeSMCProfile.load(from: path))
    }

    // MARK: SMCAccess

    public func dataSize(_ key: String) -> Int? {
        guard let entry = entries[key], entry.errorCode == nil else { return nil }
        return entry.bytes.count
    }

    public func read(_ key: String) throws -> SMCValue {
        let entry = try accessible(key)
        return SMCValue(key: key, type: entry.type, bytes: entry.bytes)
    }

    public func write(_ key: String, bytes: [UInt8]) throws {
        let entry = try accessible(key)
        guard entry.bytes.count == bytes.count else {
            throw SMCError.sizeMismatch(key, expected: entry.bytes.count, got: bytes.count)
        }
        writes.append(SMCWrite(key, bytes))
        if rejectsFirmwareLimit && (key == FirmwareLimit.upperKey || key == FirmwareLimit.lowerKey) { return }
        entries[key]?.bytes = bytes
        updateFirmwareHolding()
    }

    private func accessible(_ key: String) throws -> Entry {
        guard let entry = entries[key] else { throw SMCError.keyNotFound(key) }
        if let code = entry.errorCode { throw SMCError.callFailed(code) }
        return entry
    }

    // MARK: Simulazione

    /// Da qui in poi ogni operazione sulla chiave fallisce con questo codice (SMC che smette di rispondere)
    public func failKey(_ key: String, code: kern_return_t = kern_return_t(bitPattern: 0xe00002c1)) {
        entries[key]?.errorCode = code
    }

    public func bytes(_ key: String) -> [UInt8]? {
        entries[key]?.bytes
    }

    public var isChargeInhibited: Bool {
        let chte = entries["CHTE"].map { $0.bytes.count == 4 && $0.bytes.contains { $0 != 0 } } ?? false
        let ch0b = entries["CH0B"].map { $0.bytes.count == 1 && $0.bytes[0] != 0 } ?? false
        let ch0c = entries["CH0C"].map { $0.bytes.count == 1 && $0.bytes[0] != 0 } ?? false
        return chte || ch0b || ch0c || firmwareHolding
    }

    public var isAdapterCut: Bool {
        AdapterPower.candidates.contains { candidate in
            guard let entry = entries[candidate.key], entry.errorCode == nil, entry.bytes.count == 1 else { return false }
            return AdapterPower.isCut(entry.bytes)
        }
    }

    /// Con l'alimentazione staccata macOS si comporta come a cavo tolto (batt, README "Enable/disable power adapter")
    public var isOnWallPower: Bool {
        pluggedIn && !isAdapterCut
    }

    public var isCharging: Bool {
        isOnWallPower && !isChargeInhibited && percent < 100
    }

    public var battery: BatteryStatus {
        BatteryStatus(percent: Int(percent.rounded()), isCharging: isCharging,
                      externalConnected: isOnWallPower, fullyCharged: percent >= 100)
    }

    /// Fa passare il tempo a passi di un secondo: il limite firmware interviene appena la carica tocca la soglia
    public func advance(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        var remaining = seconds
        while remaining > 0 {
            let step = min(1, remaining)
            updateFirmwareHolding()
            if isCharging {
                percent = min(100, percent + chargePerMinute * step / 60)
            } else if !isOnWallPower {
                percent = max(0, percent - drainPerMinute * step / 60)
            }
            remaining -= step
        }
        updateFirmwareHolding()
        syncBatteryKey()
    }

    private var firmwareLimit: FirmwareLimit? {
        guard let activation = entries[FirmwareLimit.activationKey], activation.errorCode == nil,
              let upper = entries[FirmwareLimit.upperKey], upper.errorCode == nil,
              let lower = entries[FirmwareLimit.lowerKey], lower.errorCode == nil else { return nil }
        return FirmwareLimit.decode(activation: activation.bytes, upper: upper.bytes, lower: lower.bytes)
    }

    private func updateFirmwareHolding() {
        guard let limit = firmwareLimit, limit.isActive else {
            firmwareHolding = false
            return
        }
        if percent >= Double(limit.upper) {
            firmwareHolding = true
        } else if percent <= Double(limit.lower) {
            firmwareHolding = false
        }
    }

    /// BUIC (percentuale ui8) segue la carica simulata, come sul Mac vero
    private func syncBatteryKey() {
        guard entries["BUIC"]?.bytes.count == 1 else { return }
        entries["BUIC"]?.bytes = [UInt8(percent.rounded())]
    }
}

/// Batteria simulata scritta dal servizio in modalità di prova, letta dall'app: in una macchina virtuale
/// non c'è batteria vera e il pannello resterebbe su "Batteria non rilevata".
public enum FakeBatterySnapshot {
    public static func path(nextTo statusPath: String) -> String {
        (statusPath as NSString).deletingLastPathComponent + "/fake-battery"
    }

    public static func serialize(_ battery: BatteryStatus) -> String {
        "percent=\(battery.percent)\ncharging=\(battery.isCharging ? 1 : 0)\nplugged=\(battery.externalConnected ? 1 : 0)\n"
    }

    public static func parse(_ text: String) -> BatteryStatus? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let percent = fields["percent"].flatMap(Int.init) else { return nil }
        return BatteryStatus(percent: percent, isCharging: fields["charging"] == "1",
                             externalConnected: fields["plugged"] == "1", fullyCharged: percent >= 100)
    }
}
