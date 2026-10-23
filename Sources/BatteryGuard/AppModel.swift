import AppKit
import SMCKit

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case checking
        case notInstalled
        case installed
        /// Servizio installato che non dà segni di vita: si offre la riparazione invece di ripartire dallo stato 1
        case notResponding(lastError: String?)
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var battery: BatteryStatus?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    /// Servizio attivo ma con un binario diverso da quello nel bundle (app appena aggiornata)
    @Published private(set) var serviceNeedsUpdate = false
    @Published var isConfirmingDisable = false
    @Published var limit = Double(LimitConfig.defaultLimit)
    var isDraggingLimit = false
    /// Apre il pannello: lo imposta chi gestisce l'icona nella barra dei menu.
    var requestPanel: (() -> Void)?

    private var lastWrittenLimit: Int?
    private var pendingWrite: Task<Void, Never>?
    private var batteryTimer: Timer?
    private var keyWindowObserver: NSObjectProtocol?

    init() {
        refreshBattery()
        refreshService()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.refreshBattery() }
        }
        // Il pannello della barra dei menu diventa finestra principale a ogni apertura: è il momento di ricontrollare
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in
                model.refreshBattery()
                model.refreshService()
            }
        }
    }

    var limitValue: Int { Int(limit.rounded()) }

    func refreshBattery() {
        battery = Battery.read()
    }

    func refreshService() {
        guard !isBusy else { return }
        Task {
            let health = await Task.detached { HelperInstaller.checkHealth() }.value
            apply(health)
            await refreshServiceVersion()
        }
    }

    private func refreshServiceVersion() async {
        guard phase == .installed else {
            serviceNeedsUpdate = false
            return
        }
        serviceNeedsUpdate = await Task.detached { HelperInstaller.serviceNeedsUpdate() }.value
    }

    private func apply(_ health: ServiceHealth) {
        let wasInstalled = phase == .installed
        let isFirstCheck = phase == .checking
        switch health {
        case .notInstalled: phase = .notInstalled
        case .running: phase = .installed
        case .notResponding(let lastError): phase = .notResponding(lastError: lastError)
        }
        // Primo avvio senza servizio: l'invito ad attivare il limite si mostra da solo
        if isFirstCheck && health == .notInstalled {
            requestPanel?()
        }
        if health == .running && !wasInstalled, let saved = LimitConfig.read() {
            limit = Double(saved)
            lastWrittenLimit = saved
        }
    }

    func install() {
        perform(expectRunning: true, failureMessage: { String(localized: "Couldn’t turn on the limit: \($0)") }) { [limitValue] in
            HelperInstaller.install(limit: limitValue)
        }
    }

    /// Stessa installazione dell'attivazione, con la soglia già salvata: password una volta, solo dopo un clic.
    func updateService() {
        perform(expectRunning: true, failureMessage: { String(localized: "Couldn’t update the service: \($0)") }) { [limitValue] in
            HelperInstaller.install(limit: limitValue)
        }
    }

    func uninstall() {
        isConfirmingDisable = false
        perform(expectRunning: false, failureMessage: { String(localized: "Couldn’t turn off the limit: \($0)") }) {
            HelperInstaller.uninstall()
        }
    }

    private func perform(expectRunning: Bool, failureMessage: @escaping (String) -> String, _ action: @escaping @Sendable () -> HelperInstaller.Outcome) {
        isBusy = true
        errorMessage = nil
        Task {
            // Il dialogo della password blocca il processo chiamante: fuori dal main thread
            let outcome = await Task.detached(operation: action).value
            if case .failed(let detail) = outcome {
                errorMessage = failureMessage(detail)
            }
            // launchd può impiegare un attimo ad avviare o fermare il servizio
            var health = await Task.detached { HelperInstaller.checkHealth() }.value
            if case .success = outcome {
                for _ in 0..<6 where (health == .running) != expectRunning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    health = await Task.detached { HelperInstaller.checkHealth() }.value
                }
            }
            isBusy = false
            apply(health)
            await refreshServiceVersion()
        }
    }

    /// Da tastiera e VoiceOver la batteria non segnala inizio e fine trascinamento: si scrive dopo una breve pausa.
    func limitChanged() {
        guard !isDraggingLimit else { return }
        pendingWrite?.cancel()
        pendingWrite = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commitLimit()
        }
    }

    func commitLimit() {
        pendingWrite?.cancel()
        let value = limitValue
        guard value != lastWrittenLimit else { return }
        do {
            try HelperInstaller.writeLimit(value)
            lastWrittenLimit = value
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Couldn’t save the limit: \(error.localizedDescription)")
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
