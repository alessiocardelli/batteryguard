import AppKit
import SMCKit

@MainActor
final class AppModel: ObservableObject {
    enum Phase {
        case checking
        case notInstalled
        case installed
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var battery: BatteryStatus?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published var isConfirmingDisable = false
    @Published var limit = Double(LimitConfig.defaultLimit)
    var isDraggingLimit = false

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
            let running = await Task.detached { HelperInstaller.isRunning }.value
            apply(running: running)
        }
    }

    private func apply(running: Bool) {
        let wasInstalled = phase == .installed
        phase = running ? .installed : .notInstalled
        if running && !wasInstalled, let saved = LimitConfig.read() {
            limit = Double(saved)
            lastWrittenLimit = saved
        }
    }

    func install() {
        perform(expectRunning: true, failurePrefix: "Attivazione non riuscita") { [limitValue] in
            HelperInstaller.install(limit: limitValue)
        }
    }

    func uninstall() {
        isConfirmingDisable = false
        perform(expectRunning: false, failurePrefix: "Disattivazione non riuscita") {
            HelperInstaller.uninstall()
        }
    }

    private func perform(expectRunning: Bool, failurePrefix: String, _ action: @escaping @Sendable () -> HelperInstaller.Outcome) {
        isBusy = true
        errorMessage = nil
        Task {
            // Il dialogo della password blocca il processo chiamante: fuori dal main thread
            let outcome = await Task.detached(operation: action).value
            if case .failed(let detail) = outcome {
                errorMessage = "\(failurePrefix): \(detail)"
            }
            // launchd può impiegare un attimo ad avviare o fermare il servizio
            var running = await Task.detached { HelperInstaller.isRunning }.value
            if case .success = outcome {
                for _ in 0..<6 where running != expectRunning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    running = await Task.detached { HelperInstaller.isRunning }.value
                }
            }
            isBusy = false
            apply(running: running)
        }
    }

    /// Da tastiera lo slider non segnala inizio e fine trascinamento: si scrive dopo una breve pausa.
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
            errorMessage = "Non riesco a salvare la soglia: \(error.localizedDescription)"
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
