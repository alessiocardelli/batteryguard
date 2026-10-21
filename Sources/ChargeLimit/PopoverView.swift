import SwiftUI
import SMCKit

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.phase {
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .notInstalled:
                activationSection
            case .installed:
                statusSection
                Divider()
                limitSection
                Divider()
                if model.isConfirmingDisable {
                    disableConfirmation
                } else {
                    footer
                }
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.phase == .notInstalled {
                HStack {
                    Spacer()
                    quitButton
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: Stato 1: servizio non installato

    private var activationSection: some View {
        VStack(spacing: 8) {
            Button { model.install() } label: {
                Group {
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Attiva il limite di ricarica")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy)

            Text("Serve la password di amministratore, una volta sola")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Stato 2: servizio attivo

    @ViewBuilder
    private var statusSection: some View {
        if let battery = model.battery {
            VStack(alignment: .leading, spacing: 12) {
                BatteryGauge(percent: battery.percent, limit: model.limitValue, isCharging: battery.isCharging)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(battery.percent)%")
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                    chargingLabel(for: battery)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text("Batteria non rilevata")
                .foregroundStyle(.secondary)
        }
    }

    private func chargingLabel(for battery: BatteryStatus) -> Label<Text, Image> {
        if battery.isCharging {
            return Label("In carica", systemImage: "bolt.fill")
        }
        if battery.externalConnected {
            return Label("In pausa", systemImage: "pause.circle.fill")
        }
        return Label("Alimentatore scollegato", systemImage: "powerplug")
    }

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ricarica massima")
                Spacer()
                Text("\(model.limitValue)%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)

            Slider(value: $model.limit, in: 50...100, step: 5) {
                Text("Ricarica massima")
            } minimumValueLabel: {
                Text("50%").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("100%").font(.caption).foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                model.isDraggingLimit = editing
                if !editing { model.commitLimit() }
            }
            .labelsHidden()
            .accessibilityValue("\(model.limitValue)%")
            .onChange(of: model.limit) { _ in model.limitChanged() }
        }
    }

    private var footer: some View {
        HStack {
            Button("Disattiva il limite") { model.isConfirmingDisable = true }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(model.isBusy)
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            quitButton
        }
    }

    private var disableConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Disattivare il limite?")
                .font(.headline)
            Text("La batteria tornerà a caricarsi al 100%.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annulla") { model.isConfirmingDisable = false }
                    .keyboardShortcut(.cancelAction)
                Button("Disattiva", role: .destructive) { model.uninstall() }
            }
        }
    }

    private var quitButton: some View {
        Button("Esci") { model.quit() }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Chiude l'app; il limite resta attivo")
    }
}
