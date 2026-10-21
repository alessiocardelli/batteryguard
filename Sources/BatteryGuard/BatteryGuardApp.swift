import SwiftUI

@main
struct BatteryGuardApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("BatteryGuard")
        }
        .menuBarExtraStyle(.window)
    }
}
