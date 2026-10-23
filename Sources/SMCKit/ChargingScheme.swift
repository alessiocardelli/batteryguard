import Foundation

/// Schema di controllo della ricarica: dipende dal firmware SMC del Mac, non dalla versione di macOS.
/// Fatti tecnici ricavati studiando batt e Battery Toolkit (documentazione, issue e comportamento), codice nostro.
public enum ChargingScheme: String {
    /// Firmware più recenti: è il firmware stesso a tenere la carica tra una soglia inferiore e una superiore
    case firmware
    /// Firmware Apple Silicon recenti (macOS 15+): una chiave a 4 byte
    case chte = "CHTE"
    /// Firmware precedenti: due chiavi a 1 byte che vanno scritte insieme
    case ch0bc = "CH0B+CH0C"

    /// Tutte le chiavi che il rilevamento considera, nell'ordine di precedenza
    public static let candidateKeys = FirmwareLimit.keys + ["CHTE", "CH0B", "CH0C"]

    /// Sceglie lo schema dalla presenza delle chiavi; nil = Mac non supportato.
    /// `keySize` restituisce la dimensione dichiarata dall'SMC, nil se la chiave non esiste.
    /// Le chiavi firmware hanno la precedenza: un macOS vecchio può ricevere il firmware nuovo, e lì
    /// CHTE o CH0B/CH0C possono esistere senza avere effetto. Contano però solo con le dimensioni che
    /// sappiamo scrivere (1, 4, 4 byte): alcuni firmware espongono segnaposto a dimensione zero, e su un
    /// firmware CHTE (macOS 26) bfD0 esiste con 2 byte, quindi è un'altra cosa.
    public static func detect(keySize: (String) -> Int?) -> ChargingScheme? {
        if zip(FirmwareLimit.keys, FirmwareLimit.sizes).allSatisfy({ keySize($0) == $1 }) { return .firmware }
        if keySize("CHTE") != nil { return .chte }
        if keySize("CH0B") != nil && keySize("CH0C") != nil { return .ch0bc }
        return nil
    }

    /// Chiavi dello schema legacy, scritte con gli stessi byte
    var legacyKeys: [String] {
        switch self {
        case .firmware: return []
        case .chte: return ["CHTE"]
        case .ch0bc: return ["CH0B", "CH0C"]
        }
    }

    func legacyBytes(enabled: Bool) -> [UInt8] {
        switch self {
        case .firmware: return []
        case .chte: return enabled ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00]
        case .ch0bc: return enabled ? [0x00] : [0x02]
        }
    }
}

/// Una scrittura SMC: chiave e byte grezzi.
public struct SMCWrite: Equatable {
    public let key: String
    public let bytes: [UInt8]

    public init(_ key: String, _ bytes: [UInt8]) {
        self.key = key
        self.bytes = bytes
    }
}

/// Limite gestito dal firmware: attivazione (bfF0, 1 byte) e soglie superiore (bfD0) e inferiore (bfE0).
/// Le soglie sono percentuali uint32 in ordine little-endian (50% = 32 00 00 00), al contrario
/// della convenzione big-endian delle altre chiavi intere dell'SMC.
public struct FirmwareLimit: Equatable {
    public static let activationKey = "bfF0"
    public static let upperKey = "bfD0"
    public static let lowerKey = "bfE0"
    public static let keys = [activationKey, upperKey, lowerKey]
    /// Dimensioni in byte, nello stesso ordine di `keys`
    public static let sizes = [1, 4, 4]

    public static let activeByte: UInt8 = 0x02
    public static let inactiveByte: UInt8 = 0x00

    /// Byte grezzo di bfF0: attivo solo con 0x02, qualunque altro valore non è il nostro limite
    public var activation: UInt8
    public var upper: Int
    public var lower: Int

    public init(activation: UInt8, upper: Int, lower: Int) {
        self.activation = activation
        self.upper = upper
        self.lower = lower
    }

    public var isActive: Bool { activation == Self.activeByte }

    public static func encodePercent(_ value: Int) -> [UInt8] {
        let raw = UInt32(clamping: value)
        return (0..<4).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt32($0))) }
    }

    /// nil se la dimensione non è quella attesa o il valore non è una percentuale
    public static func decodePercent(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == 4 else { return nil }
        let value = bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) }
        return value <= 100 ? Int(value) : nil
    }

    /// Stato letto dai byte delle tre chiavi; nil se uno dei valori non è decodificabile
    public static func decode(activation: [UInt8], upper: [UInt8], lower: [UInt8]) -> FirmwareLimit? {
        guard activation.count == 1, let upperValue = decodePercent(upper), let lowerValue = decodePercent(lower) else { return nil }
        return FirmwareLimit(activation: activation[0], upper: upperValue, lower: lowerValue)
    }

    /// Scritture per arrivare al limite attivo tra `lower` e `upper`, vuote se è già così.
    /// L'ordine lo richiede il firmware: si disattiva, si scrivono le soglie, si riattiva.
    /// Uno stato illeggibile (nil) si riscrive da capo.
    public static func writesToActivate(upper: Int, lower: Int, current: FirmwareLimit?) -> [SMCWrite] {
        precondition(lower >= 0 && upper <= 100 && lower < upper, "soglie firmware non valide: \(lower)-\(upper)")
        if let current, current.isActive, current.upper == upper, current.lower == lower { return [] }
        return [
            SMCWrite(activationKey, [inactiveByte]),
            SMCWrite(upperKey, encodePercent(upper)),
            SMCWrite(lowerKey, encodePercent(lower)),
            SMCWrite(activationKey, [activeByte])
        ]
    }

    /// Scritture per spegnere il limite (ricarica normale), vuote se bfF0 è già 0x00
    public static func writesToDeactivate(currentActivation: UInt8?) -> [SMCWrite] {
        currentActivation == inactiveByte ? [] : [SMCWrite(activationKey, [inactiveByte])]
    }
}
