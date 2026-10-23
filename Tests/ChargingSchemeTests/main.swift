// Scelta dello schema di ricarica e codifica delle chiavi firmware (bfF0, bfD0, bfE0).
// Si compila insieme a ChargingScheme.swift con scripts/test.sh: niente SMC vero, le chiavi sono simulate.

import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, _ line: UInt = #line) {
    if !condition {
        failures += 1
        print("FALLITO riga \(line): \(message)")
    }
}

// MARK: Rilevamento per presenza delle chiavi (chiave -> dimensione dichiarata)

func detect(_ keys: [String: Int]) -> ChargingScheme? {
    ChargingScheme.detect { keys[$0] }
}

let firmwareKeys = ["bfF0": 1, "bfD0": 4, "bfE0": 4]
check(detect(firmwareKeys) == .firmware, "solo chiavi firmware")
check(detect(firmwareKeys.merging(["CHTE": 4]) { $1 }) == .firmware, "firmware ha la precedenza su CHTE")
check(detect(firmwareKeys.merging(["CH0B": 1, "CH0C": 1]) { $1 }) == .firmware, "firmware ha la precedenza su CH0B+CH0C")
check(detect(["bfF0": 0, "bfD0": 4, "bfE0": 4, "CHTE": 4]) == .chte, "bfF0 segnaposto a dimensione zero: non conta")
check(detect(["bfF0": 1, "bfD0": 4, "CHTE": 4]) == .chte, "chiavi firmware incomplete: non contano")
check(detect(["bfD0": 2, "CHTE": 4]) == .chte, "Mac di Alessio (macOS 26): bfD0 a 2 byte, CHTE")
check(detect(["bfF0": 1, "bfD0": 2, "bfE0": 4, "CHTE": 4]) == .chte, "dimensioni diverse da quelle note: non contano")
check(detect(["bfF0": 1, "bfD0": 4, "bfE0": 4, "CH0B": 1]) == .firmware, "firmware completo anche con legacy incompleto")
check(detect(["CHTE": 4, "CH0B": 1, "CH0C": 1]) == .chte, "CHTE prima di CH0B+CH0C, come nella 1.0.3")
check(detect(["CH0B": 1, "CH0C": 1]) == .ch0bc, "CH0B+CH0C")
check(detect(["CH0B": 1]) == nil, "CH0B da solo non basta")
check(detect([:]) == nil, "nessuna chiave = non supportato")
check(detect(["bfF0": 1, "bfD0": 4]) == nil, "firmware incompleto e niente legacy = non supportato")

// MARK: Codifica delle soglie: uint32 little-endian (50% = 32 00 00 00)

check(FirmwareLimit.encodePercent(50) == [0x32, 0x00, 0x00, 0x00], "50% little-endian: \(FirmwareLimit.encodePercent(50))")
check(FirmwareLimit.encodePercent(80) == [0x50, 0x00, 0x00, 0x00], "80%")
check(FirmwareLimit.encodePercent(78) == [0x4e, 0x00, 0x00, 0x00], "78%")
check(FirmwareLimit.encodePercent(100) == [0x64, 0x00, 0x00, 0x00], "100%")
check(FirmwareLimit.decodePercent([0x32, 0x00, 0x00, 0x00]) == 50, "decodifica 50%")
check(FirmwareLimit.decodePercent([0x00, 0x00, 0x00, 0x32]) == nil, "big-endian = valore fuori scala, non una percentuale")
check(FirmwareLimit.decodePercent([0x32]) == nil, "dimensione sbagliata")
check(FirmwareLimit.decodePercent([0x65, 0x00, 0x00, 0x00]) == nil, "oltre 100")
for percent in 0...100 {
    check(FirmwareLimit.decodePercent(FirmwareLimit.encodePercent(percent)) == percent, "andata e ritorno \(percent)")
}

let read = FirmwareLimit.decode(activation: [0x02], upper: [0x50, 0, 0, 0], lower: [0x4e, 0, 0, 0])
check(read == FirmwareLimit(activation: 0x02, upper: 80, lower: 78), "stato letto: \(String(describing: read))")
check(read?.isActive == true, "0x02 = attivo")
check(FirmwareLimit(activation: 0x01, upper: 80, lower: 78).isActive == false, "solo 0x02 vale come attivo")
check(FirmwareLimit.decode(activation: [], upper: [0x50, 0, 0, 0], lower: [0x4e, 0, 0, 0]) == nil, "bfF0 vuoto")
check(FirmwareLimit.decode(activation: [0x02], upper: [0x50, 0], lower: [0x4e, 0, 0, 0]) == nil, "bfD0 corto")

// MARK: Sequenza di scrittura: disattiva, superiore, inferiore, riattiva

let fullSequence = [
    SMCWrite("bfF0", [0x00]),
    SMCWrite("bfD0", [0x50, 0x00, 0x00, 0x00]),
    SMCWrite("bfE0", [0x4e, 0x00, 0x00, 0x00]),
    SMCWrite("bfF0", [0x02])
]
check(FirmwareLimit.writesToActivate(upper: 80, lower: 78, current: FirmwareLimit(activation: 0x00, upper: 100, lower: 95)) == fullSequence, "primo avvio: sequenza completa nell'ordine")
check(FirmwareLimit.writesToActivate(upper: 80, lower: 78, current: nil) == fullSequence, "stato illeggibile: si riscrive")
check(FirmwareLimit.writesToActivate(upper: 80, lower: 78, current: FirmwareLimit(activation: 0x02, upper: 80, lower: 78)).isEmpty, "già giusto: nessuna scrittura")
check(FirmwareLimit.writesToActivate(upper: 80, lower: 78, current: FirmwareLimit(activation: 0x02, upper: 80, lower: 75)) == fullSequence, "inferiore cambiato da fuori: riparato")
check(FirmwareLimit.writesToActivate(upper: 80, lower: 78, current: FirmwareLimit(activation: 0x02, upper: 100, lower: 78)) == fullSequence, "superiore cambiato da fuori (es. macOS): riparato")
check(FirmwareLimit.writesToActivate(upper: 80, lower: 78, current: FirmwareLimit(activation: 0x00, upper: 80, lower: 78)) == fullSequence, "soglie giuste ma limite spento: riattivato")
check(FirmwareLimit.writesToActivate(upper: 60, lower: 58, current: FirmwareLimit(activation: 0x02, upper: 80, lower: 78))
      == [SMCWrite("bfF0", [0x00]), SMCWrite("bfD0", [0x3c, 0, 0, 0]), SMCWrite("bfE0", [0x3a, 0, 0, 0]), SMCWrite("bfF0", [0x02])], "soglia cambiata dall'app")

check(FirmwareLimit.writesToDeactivate(currentActivation: 0x02) == [SMCWrite("bfF0", [0x00])], "disattivazione")
check(FirmwareLimit.writesToDeactivate(currentActivation: 0x00).isEmpty, "già spento: nessuna scrittura")
check(FirmwareLimit.writesToDeactivate(currentActivation: 0x01) == [SMCWrite("bfF0", [0x00])], "valore inatteso: si porta a 0x00")
check(FirmwareLimit.writesToDeactivate(currentActivation: nil) == [SMCWrite("bfF0", [0x00])], "illeggibile: si scrive 0x00")

if failures > 0 {
    print("\(failures) test falliti")
    exit(1)
}
print("ChargingScheme: tutti i test passati")
