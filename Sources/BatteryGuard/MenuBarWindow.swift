import AppKit
import SwiftUI

/// Icona nella barra dei menu e pannello. Status item AppKit invece di MenuBarExtra: serve per aprire
/// il pannello da codice (primo avvio, riapertura dell'app dal Finder) e per mostrarlo anche quando
/// macOS nasconde l'icona dietro la tacca perché la barra è piena.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private static let panelWidth: CGFloat = 296
    /// Distanza tra il bordo basso della barra e il pannello, come la finestra di MenuBarExtra
    private static let panelGap: CGFloat = 2
    private static let panelRadius: CGFloat = 6

    private enum Placement {
        case visible(NSRect, NSScreen)
        case behindNotch(NSScreen)
        /// Fuori da ogni schermo: normale subito dopo l'avvio, poi vuol dire icona nascosta
        case unplaced
    }

    /// Solo per provare il pannello fluttuante su un Mac dove l'icona si vede, o il contrario.
    private static let debugPlacement = ProcessInfo.processInfo.environment["BATTERYGUARD_DEBUG_ICON"]

    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<PopoverView>?
    private var outsideClickMonitor: Any?
    private var lastClosed = Date.distantPast
    private let launchDate = Date()

    init(model: AppModel) {
        self.model = model
        // Larga quanto il glifo: i margini ai lati (8 pt per parte su macOS 26) li aggiunge il sistema
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.image = MenuBarIcon.image
            button.setAccessibilityLabel("BatteryGuard")
            button.target = self
            button.action = #selector(togglePanel)
        }
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            closePanel()
        } else if Date().timeIntervalSince(lastClosed) > 0.3 {
            // Il clic sull'icona chiude prima il pannello (perde il fuoco): senza questa pausa si riaprirebbe subito
            showPanel()
        }
    }

    /// Subito dopo l'avvio l'icona non ha ancora il suo posto nella barra: nei primi 5 secondi si aspetta,
    /// poi un'icona fuori schermo vuol dire nascosta e il pannello si apre subito in alto al centro.
    func showPanel() {
        switch placement() {
        case .visible(let frame, let screen):
            present(on: screen, below: frame, showsNotice: false)
        case .behindNotch(let screen):
            present(on: screen, below: nil, showsNotice: true)
        case .unplaced:
            if Date().timeIntervalSince(launchDate) < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.showPanel()
                }
            } else if let screen = NSScreen.main ?? NSScreen.screens.first {
                present(on: screen, below: nil, showsNotice: false)
            }
        }
    }

    private func placement() -> Placement {
        if Self.debugPlacement == "hidden", let screen = NSScreen.main { return .behindNotch(screen) }
        guard let frame = statusItem.button?.window?.frame, frame.height > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) && abs(frame.maxY - $0.frame.maxY) < 1 })
        else { return .unplaced }
        if Self.debugPlacement == "visible" { return .visible(frame, screen) }
        // Sugli schermi con la tacca la barra è divisa in due zone libere: un'icona fuori da entrambe sta dietro la tacca
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           !left.insetBy(dx: -1, dy: -1).contains(frame), !right.insetBy(dx: -1, dy: -1).contains(frame) {
            return .behindNotch(screen)
        }
        return .visible(frame, screen)
    }

    /// Con `itemFrame` il pannello si aggancia sotto l'icona, senza si apre in alto al centro dello schermo.
    private func present(on screen: NSScreen, below itemFrame: NSRect?, showsNotice: Bool) {
        let panel = panel ?? makePanel()
        let hostingView = hostingView ?? makeHostingView(in: panel)
        let content = PopoverView(model: model, showsHiddenIconNotice: showsNotice)
        hostingView.rootView = content
        // Misura su una vista a parte: quella nel pannello non impone dimensioni (sizingOptions vuoto) e darebbe 0.
        // Dopo l'apertura l'altezza la segue fitsMenuBarPanel
        let size = NSSize(width: Self.panelWidth, height: NSHostingView(rootView: content).fittingSize.height)

        // Sotto la barra dei menu anche se si nasconde da sola (visibleFrame arriva allora fino in cima)
        let menuBarBottom = itemFrame?.minY ?? min(screen.visibleFrame.maxY, screen.frame.maxY - NSStatusBar.system.thickness)
        let preferredX = itemFrame?.minX ?? screen.frame.midX - size.width / 2
        let x = min(max(preferredX, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: menuBarBottom - Self.panelGap - size.height, width: size.width, height: size.height), display: true)

        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(itemFrame != nil)
        // Clic in un'altra app: il pannello si chiude come un menu
        outsideClickMonitor = outsideClickMonitor ?? NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        lastClosed = Date()
        statusItem.button?.highlight(false)
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.delegate = self

        // Angoli come la finestra di MenuBarExtra della 1.0.2 (6 pt, misurati)
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.panelRadius)
        panel.contentView = background
        self.panel = panel
        return panel
    }

    private func makeHostingView(in panel: FloatingPanel) -> NSHostingView<PopoverView> {
        let hostingView = NSHostingView(rootView: PopoverView(model: model))
        // L'altezza la decide fitsMenuBarPanel: niente vincoli di dimensione dalla vista SwiftUI sulla finestra
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        if let contentView = panel.contentView {
            hostingView.frame = contentView.bounds
            contentView.addSubview(hostingView)
        }
        self.hostingView = hostingView
        return hostingView
    }

    /// Maschera elastica (capInsets): gli angoli restano tondi qualunque sia l'altezza del pannello.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Pannello senza bordi che prende la tastiera (frecce sulla batteria, Tab, Esc) senza attivare l'app.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

extension View {
    /// Il pannello segue l'altezza del contenuto quando cambia (conferma di disattivazione, un errore,
    /// il passaggio da uno stato all'altro), tenendo il bordo alto fermo sotto la barra dei menu.
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
