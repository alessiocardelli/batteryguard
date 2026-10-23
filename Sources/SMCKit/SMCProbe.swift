import Foundation

/// Lettura delle chiavi di ricarica, senza scrivere nulla: la usano il comando `probe` del servizio
/// e la segnalazione dell'app. Le etichette restano quelle della 1.0.4 (docs/TEST-FIRMWARE.md le spiega).
public enum SMCProbe {
    public static let keys = FirmwareLimit.keys + ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "BUIC", "B0RM"]

    public static func lines(_ smc: SMCAccess) -> [String] {
        var lines = keys.map { key -> String in
            do {
                let value = try smc.read(key)
                var line = "\(key)  tipo=\(value.type)  byte=\(value.bytes.count)  valore=\(value.hex)"
                if key == FirmwareLimit.upperKey || key == FirmwareLimit.lowerKey,
                   let percent = FirmwareLimit.decodePercent(value.bytes) {
                    line += "  (\(percent)%)"
                }
                return line
            } catch {
                return "\(key)  \(error)"
            }
        }
        lines.append("schema rilevato: \(ChargingScheme.detect(keySize: smc.dataSize)?.rawValue ?? "nessuno (non supportato)")")
        return lines
    }
}
