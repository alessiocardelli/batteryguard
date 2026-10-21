import AppKit
import SwiftUI

/// MenuBarExtra non ha un'API per aprire il pannello: si simula il clic sul bottone dell'icona
/// nella barra dei menu, che vive in una finestra dell'app come ogni status item.
enum MenuBarPanel {
    @MainActor
    static func open(attempts: Int = 25) {
        // Subito dopo l'avvio l'icona non ha ancora il suo posto nella barra (la finestra è fuori schermo):
        // aprendo ora, il pannello comparirebbe fuori schermo. Si aspetta che sia sistemata
        if let button = statusItemButton(), let frame = button.window?.frame, isInMenuBar(frame) {
            button.performClick(nil)
            return
        }
        guard attempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            open(attempts: attempts - 1)
        }
    }

    /// Appena creata la finestra dell'icona è vuota, poi fuori schermo e solo alla fine sulla barra:
    /// conta solo quando sta in cima a uno schermo.
    @MainActor
    private static func isInMenuBar(_ frame: NSRect) -> Bool {
        frame.height > 0 && NSScreen.screens.contains { screen in
            screen.frame.contains(frame) && frame.minX > screen.frame.minX && abs(frame.maxY - screen.frame.maxY) < 1
        }
    }

    @MainActor
    private static func statusItemButton() -> NSStatusBarButton? {
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = firstStatusButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func firstStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = firstStatusButton(in: subview) { return button }
        }
        return nil
    }
}

extension View {
    /// MenuBarExtra allarga il pannello quando il contenuto cresce ma non lo riduce quando si accorcia
    /// (dopo la conferma di disattivazione, un errore, il passaggio dallo stato 1 al 2): lo sfondo resta
    /// alto quanto il contenuto e sopra e sotto compaiono fasce vuote. Qui il pannello segue il contenuto.
    func fitsMenuBarPanel() -> some View {
        background {
            GeometryReader { proxy in
                MenuBarPanelFitter(height: proxy.size.height)
            }
        }
    }
}

private struct MenuBarPanelFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        // Dopo il ciclo di layout in corso, quando la finestra è già agganciata alla vista
        DispatchQueue.main.async {
            guard let window = view.window, height > 0 else { return }
            let current = window.contentRect(forFrameRect: window.frame)
            guard abs(current.height - height) > 0.5 else { return }
            // Il bordo alto resta attaccato alla barra dei menu
            let content = NSRect(x: current.minX, y: current.maxY - height, width: current.width, height: height)
            window.setFrame(window.frameRect(forContentRect: content), display: true)
        }
    }
}
