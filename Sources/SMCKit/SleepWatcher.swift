import Foundation
import IOKit
import IOKit.pwr_mgt

/// Notifiche di sonno e risveglio del sistema (IORegisterForSystemPower), consegnate sulla coda principale:
/// la stessa del ciclo, così non si sovrappongono a un ciclo in corso.
public final class SleepWatcher {
    // Le macro iokit_common_msg di IOMessage.h non arrivano in Swift: sys_iokit (0xE0000000) | codice
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let onWillSleep: () -> Void
    private let onDidWake: () -> Void
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    public init(onWillSleep: @escaping () -> Void, onDidWake: @escaping () -> Void) {
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
    }

    /// false se il sistema non accetta la registrazione
    public func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<SleepWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(messageType, argument)
        }, &notifier)
        guard rootPort != 0, let port else { return false }
        IONotificationPortSetDispatchQueue(port, .main)
        return true
    }

    private func handle(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep:
            // Il sonno per inattività non si nega mai: la sicurezza sta nel riattaccare prima del sonno
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            // Senza la risposta il sistema aspetta 30 secondi prima di dormire
            onWillSleep()
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onDidWake()
        default:
            break
        }
    }
}
