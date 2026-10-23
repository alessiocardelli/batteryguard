import AppKit

/// Ciclo di vita AppKit senza scene SwiftUI: l'interfaccia è tutta nel pannello della barra dei menu,
/// e una scena (anche solo Settings) farebbe comparire una finestra vuota quando l'app viene riaperta.
@main
enum BatteryGuardApp {
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let updater = Updater()
        let menuBar = MenuBarController(model: model, updater: updater)
        model.requestPanel = { [weak menuBar] in menuBar?.showPanel() }
        self.menuBar = menuBar
        updater.start()
    }

    /// App già aperta e riaperta dal Finder o da Launchpad: senza finestre non succederebbe nulla, si apre il pannello.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.showPanel()
        return false
    }
}
