import Foundation
import IOKit

/// Coperchio del MacBook, dalla chiave AppleClamshellState di IOPMrootDomain: si legge anche senza root.
public enum Lid {
    public static let stateKey = "AppleClamshellState"

    /// nil = chiave assente (Mac senza coperchio, come Mac mini e iMac): per il servizio vale come aperto
    public static func isClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, stateKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return value as? Bool
    }
}

/// Notifica di apertura e chiusura del coperchio (kIOPMMessageClamshellStateChange sull'interesse generale
/// di IOPMrootDomain), consegnata sulla coda principale come le notifiche di sonno e il ciclo.
/// Serve a reagire prima che macOS decida lo stop: il ciclo da 5 secondi arriverebbe tardi.
public final class LidWatcher {
    // iokit_family_msg(sub_iokit_powermanagement, 0x100): la macro non arriva in Swift
    private static let clamshellStateChange: UInt32 = 0xE003_4100
    /// kClamshellStateBit: nell'argomento del messaggio, 1 = coperchio chiuso
    private static let clamshellStateBit = 1

    private let onChange: (Bool) -> Void
    private var port: IONotificationPortRef?
    private var notification: io_object_t = 0

    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    /// false se IOPMrootDomain non c'è o non accetta la registrazione
    public func start() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, messageType, argument in
            guard let refcon, messageType == LidWatcher.clamshellStateChange else { return }
            let closed = Int(bitPattern: argument) & LidWatcher.clamshellStateBit != 0
            Unmanaged<LidWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange(closed)
        }, refcon, &notification)
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return false
        }
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port
        return true
    }
}
