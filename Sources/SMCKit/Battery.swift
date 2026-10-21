import Foundation
import IOKit

public struct BatteryStatus {
    public let percent: Int
    public let isCharging: Bool
    public let externalConnected: Bool
    public let fullyCharged: Bool
}

public enum Battery {
    /// Legge lo stato da AppleSmartBattery. Su Apple Silicon CurrentCapacity è già in percentuale
    /// e MaxCapacity vale 100; il rapporto funziona comunque anche sui Mac Intel (mAh).
    public static func read() -> BatteryStatus? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              let current = properties["CurrentCapacity"] as? Int,
              let max = properties["MaxCapacity"] as? Int, max > 0
        else { return nil }

        return BatteryStatus(
            percent: Int((Double(current) / Double(max) * 100).rounded()),
            isCharging: properties["IsCharging"] as? Bool ?? false,
            externalConnected: properties["ExternalConnected"] as? Bool ?? false,
            fullyCharged: properties["FullyCharged"] as? Bool ?? false
        )
    }
}
