import SwiftUI

@main
struct ChargeLimitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Charge Limit")
        }
        .menuBarExtraStyle(.window)
    }
}
