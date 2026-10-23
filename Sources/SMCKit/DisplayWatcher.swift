import Foundation
import IOKit

/// Monitor esterni dall'IORegistry, senza sessione grafica: il servizio root non può usare CoreGraphics.
/// Su Apple Silicon il coprocessore video (DCP) pubblica un DCPAVServiceProxy per ogni schermo attivo, con
/// `Location` = "Embedded" per quello del MacBook e "External" per ogni monitor collegato (DisplayPort, HDMI, USB-C).
/// Il nodo nasce quando il monitor viene collegato e sparisce quando si scollega.
/// Non li vede: schermi via software (DisplayLink, Sidecar, AirPlay), che non passano dal DCP.
public enum ExternalDisplay {
    public static let serviceClass = "DCPAVServiceProxy"
    public static let locationKey = "Location"
    public static let externalLocation = "External"

    public static func isConnected() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let location = IORegistryEntryCreateCFProperty(service, locationKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == externalLocation { found = true }
        }
        return found
    }
}

/// Notifiche IOKit di arrivo e rimozione dei DCPAVServiceProxy, consegnate sulla coda principale come il ciclo:
/// a ogni notifica si riconta, così un monitor tolto mentre ne resta un altro non conta come scollegamento.
public final class DisplayWatcher {
    private let onChange: (Bool) -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    /// false se IOKit non accetta la registrazione
    public func start() -> Bool {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            DisplayWatcher.drain(iterator)
            guard let refcon else { return }
            Unmanaged<DisplayWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange(ExternalDisplay.isConnected())
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, IOServiceMatching(ExternalDisplay.serviceClass),
                                                          callback, refcon, &iterator)
            guard result == KERN_SUCCESS else {
                iterators.forEach { IOObjectRelease($0) }
                iterators = []
                IONotificationPortDestroy(port)
                return false
            }
            // Le notifiche si armano solo dopo aver svuotato l'iteratore la prima volta
            Self.drain(iterator)
            iterators.append(iterator)
        }
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port
        return true
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}
