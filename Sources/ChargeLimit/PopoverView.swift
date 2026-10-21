import SwiftUI
import SMCKit

struct PopoverView: View {
    @ObservedObject var model: AppModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var isDark: Bool { colorScheme == .dark }
    private var secondaryText: Color { Palette.secondaryText(isDark: isDark, highContrast: contrast == .increased) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.phase {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .notInstalled:
                activationSection
            case .installed:
                statusSection
                limitSection
                    .padding(.top, 24)
                if model.isConfirmingDisable {
                    disableConfirmation
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                } else {
                    hairline
                        .padding(.top, 20)
                    footer
                        .padding(.top, 8)
                }
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            if model.phase == .notInstalled {
                hairline
                    .padding(.top, 20)
                HStack {
                    Spacer()
                    quitButton
                }
                .padding(.horizontal, -8)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(width: 296)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(contrast == .increased ? 0.3 : 0.1))
            .frame(height: 1)
    }

    // MARK: Stato 1: servizio non installato

    private var activationSection: some View {
        VStack(spacing: 0) {
            BatteryGauge(percent: nil, limit: nil, isCharging: false)
                .frame(maxWidth: .infinity)

            Button { model.install() } label: {
                Group {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .colorScheme(.light)
                    } else {
                        Text("Attiva il limite di ricarica")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(EnergyButtonStyle())
            .disabled(model.isBusy)
            .padding(.top, 24)

            Text("Serve la password di amministratore,\nuna volta sola")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Stato 2: servizio attivo

    @ViewBuilder
    private var statusSection: some View {
        if let battery = model.battery {
            VStack(alignment: .leading, spacing: 16) {
                BatteryGauge(percent: battery.percent, limit: model.limitValue, isCharging: battery.isCharging)
                    .frame(maxWidth: .infinity)

                // Etichette lunghe (alimentatore scollegato) vanno sotto la percentuale invece di andare a capo
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        percentText(battery.percent)
                        Spacer(minLength: 12)
                        chargingLabel(for: battery)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        percentText(battery.percent)
                        chargingLabel(for: battery)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text("Batteria non rilevata")
                .foregroundStyle(secondaryText)
        }
    }

    private func percentText(_ percent: Int) -> some View {
        (Text("\(percent)")
            .font(.system(size: 40, weight: .semibold, design: .rounded))
            + Text("%")
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundColor(secondaryText))
            .monospacedDigit()
            .fixedSize()
    }

    private func chargingLabel(for battery: BatteryStatus) -> some View {
        let (title, symbol): (String, String) = {
            if battery.isCharging { return ("In carica", "bolt.fill") }
            if battery.externalConnected { return ("In pausa", "pause.fill") }
            return ("Alimentatore scollegato", "powerplug")
        }()
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(battery.isCharging ? Palette.ink : secondaryText)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(battery.isCharging
                                  ? AnyShapeStyle(LinearGradient(colors: [Palette.energyTop, Palette.energyMid], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Color.primary.opacity(0.08)))
                )
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ricarica massima")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                // Pillola d'energia: il testo scuro sull'arancione regge il contrasto con qualsiasi sfondo dietro il materiale
                Text("\(model.limitValue)%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 20)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [Palette.energyTop, Palette.energyMid], startPoint: .top, endPoint: .bottom)
                                .shadow(.inner(color: Color.white.opacity(0.5), radius: 0.5, y: 0.5))
                        )
                    )
            }
            .accessibilityHidden(true)

            LimitSlider(value: $model.limit, range: 50...100, step: 5, label: "Ricarica massima") { editing in
                model.isDraggingLimit = editing
                if !editing { model.commitLimit() }
            }
            .onChange(of: model.limit) { _ in model.limitChanged() }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Disattiva il limite") { model.isConfirmingDisable = true }
                .buttonStyle(QuietButtonStyle())
                .disabled(model.isBusy)
            if model.isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            quitButton
        }
        // Il testo dei bottoni si allinea al bordo del contenuto, l'alone al passaggio sborda
        .padding(.horizontal, -8)
    }

    private var disableConfirmation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Disattivare il limite?")
                .font(.system(size: 13, weight: .semibold))
            Text("La batteria tornerà a caricarsi al 100%.")
                .font(.system(size: 12))
                .foregroundStyle(secondaryText)
            HStack(spacing: 8) {
                Spacer()
                Button("Annulla") { model.isConfirmingDisable = false }
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Disattiva", role: .destructive) { model.uninstall() }
                    .buttonStyle(DestructiveButtonStyle())
            }
            .padding(.top, 12)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.06 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : 0.08), lineWidth: 1)
        )
    }

    private var quitButton: some View {
        Button("Esci") { model.quit() }
            .buttonStyle(QuietButtonStyle())
            .help("Chiude l'app; il limite resta attivo")
    }
}
