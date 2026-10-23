import Foundation
import SMCKit

extension ServiceError {
    /// Messaggio per l'utente nella lingua dell'app; nil per un codice sconosciuto (es. servizio 1.0.3,
    /// che scriveva una frase in italiano): in quel caso resta solo il testo grezzo come dettaglio.
    var localizedMessage: String? {
        switch knownCode {
        case .noChargeKeys: return String(localized: "This Mac uses charge-control keys BatteryGuard doesn’t support yet.")
        case .smcUnavailable: return String(localized: "BatteryGuard can’t access the battery controller (SMC).")
        case .smcFailed: return String(localized: "BatteryGuard couldn’t read or change the charging setting.")
        case .firmwareRejected: return String(localized: "This Mac didn’t accept the charge limit.")
        case .batteryUnreadable: return String(localized: "BatteryGuard can’t read the battery level.")
        case nil: return nil
        }
    }

    /// Dettaglio tecnico da copiare in una segnalazione
    var technicalDetail: String {
        knownCode == nil ? code : [code, detail].compactMap { $0 }.joined(separator: ": ")
    }
}
