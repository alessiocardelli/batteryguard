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
    /// Riserva per il firmware che blocca le chiavi di ricarica (macOS 27 beta 4+, 15.8, 26.7): non si ferma la
    /// ricarica, si stacca l'alimentazione dalla presa sopra la soglia e la si riattacca sotto (batt #152, #154)
    case adapter

    /// Tutte le chiavi che il rilevamento considera, nell'ordine di precedenza
    public static let candidateKeys = FirmwareLimit.keys + ["CHTE", "CH0B", "CH0C"]

    /// Sceglie lo schema dalla presenza delle chiavi; nil = Mac non supportato.
    /// `keySize` restituisce la dimensione dichiarata dall'SMC, nil se la chiave non esiste.
    /// Le chiavi firmware hanno la precedenza: un macOS vecchio può ricevere il firmware nuovo, e lì
    /// CHTE o CH0B/CH0C possono esistere senza avere effetto. Contano però solo con le dimensioni che
    /// sappiamo scrivere (1, 4, 4 byte): alcuni firmware espongono segnaposto a dimensione zero, e su un
    /// firmware CHTE (macOS 26) bfD0 esiste con 2 byte, quindi è un'altra cosa.
    /// Vale anche per le chiavi legacy: dal firmware di macOS 27 beta 4 (e degli aggiornamenti 15.8 e 26.7)
    /// CHTE, CH0B e CH0C restano nell'elenco ma a dimensione zero (batt issue #152), e scriverle fallirebbe a ogni ciclo.
    ///
    /// La modalità alimentatore entra solo come riserva: nessuno schema che ferma la ricarica, almeno una chiave legacy
    /// a dimensione zero (il segno del firmware bloccato) e una chiave dell'alimentatore utilizzabile.
    /// `forceAdapter` serve solo alla prova dal vivo su un Mac dove CHTE funziona (docs/TEST-ADAPTER.md).
    public static func detect(keySize: (String) -> Int?, forceAdapter: Bool = false) -> ChargingScheme? {
        let adapterAvailable = AdapterPower.select(keySize: keySize) != nil
        if forceAdapter { return adapterAvailable ? .adapter : nil }
        if zip(FirmwareLimit.keys, FirmwareLimit.sizes).allSatisfy({ keySize($0) == $1 }) { return .firmware }
        if keySize("CHTE") == 4 { return .chte }
        if keySize("CH0B") == 1 && keySize("CH0C") == 1 { return .ch0bc }
        let legacyGated = ["CHTE", "CH0B", "CH0C"].contains { keySize($0) == 0 }
        if legacyGated && adapterAvailable { return .adapter }
        return nil
    }

    /// Chiavi dello schema legacy, scritte con gli stessi byte
    var legacyKeys: [String] {
        switch self {
        case .firmware, .adapter: return []
        case .chte: return ["CHTE"]
        case .ch0bc: return ["CH0B", "CH0C"]
        }
    }

    func legacyBytes(enabled: Bool) -> [UInt8] {
        switch self {
        case .firmware, .adapter: return []
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

/// Alimentazione dalla presa: staccarla fa lo stesso effetto di togliere il cavo, anche con il cavo inserito.
/// Fatti da batt (`pkg/smc/adapter.go`, `consts_arm64.go`): 1 byte, 00 = collegata; per staccarla CH0I e CH0J
/// (firmware vecchi) vogliono 01, CHIE (firmware di Tahoe e successivi) vuole 08. Stesso ordine di precedenza di batt.
/// Sul firmware bloccato CH0I e CH0J rispondono 0xe00002c1, CHIE resta accessibile (batt #152).
public struct AdapterPower: Equatable {
    public let key: String
    public let cutByte: UInt8

    public static let attachedByte: UInt8 = 0x00
    public static let candidates = [
        AdapterPower(key: "CH0I", cutByte: 0x01),
        AdapterPower(key: "CH0J", cutByte: 0x01),
        AdapterPower(key: "CHIE", cutByte: 0x08)
    ]

    public static func select(keySize: (String) -> Int?) -> AdapterPower? {
        candidates.first { keySize($0.key) == 1 }
    }

    /// Qualunque valore diverso da 00 vuol dire alimentazione staccata, come in batt
    public static func isCut(_ bytes: [UInt8]) -> Bool {
        bytes != [attachedByte]
    }
}
