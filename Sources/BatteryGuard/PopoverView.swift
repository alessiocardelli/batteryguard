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
        .fitsMenuBarPanel()
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Battery, limit off"))
                .frame(maxWidth: .infinity)

            Button { model.install() } label: {
                Group {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .colorScheme(.light)
                    } else {
                        Text("Turn on charge limit")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(EnergyButtonStyle())
            .disabled(model.isBusy)
            .padding(.top, 24)

            Text("You’ll be asked for your administrator\npassword to turn on the charge limit")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Stato 2: servizio attivo

    @ViewBuilder
    private var statusSection: some View {
        if let battery = model.battery {
            VStack(spacing: 14) {
                AdjustableBattery(
                    percent: battery.percent,
                    isCharging: battery.isCharging,
                    limit: $model.limit,
                    range: LimitConfig.range,
                    step: 5
                ) { editing in
                    model.isDraggingLimit = editing
                    if !editing { model.commitLimit() }
                }
                .onChange(of: model.limit) { _ in model.limitChanged() }

                chargingLabel(for: battery)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text("Battery not detected")
                .foregroundStyle(secondaryText)
        }
    }

    private func chargingLabel(for battery: BatteryStatus) -> some View {
        let (title, symbol): (LocalizedStringKey, String) = {
            if battery.isCharging { return ("Charging", "bolt.fill") }
            if battery.externalConnected { return ("Paused", "pause.fill") }
            return ("Not plugged in", "powerplug")
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
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button("Turn off limit") { model.isConfirmingDisable = true }
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
            Text("Turn off the limit?")
                .font(.system(size: 13, weight: .semibold))
            Text("Your battery will charge to 100%.")
                .font(.system(size: 12))
                .foregroundStyle(secondaryText)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.isConfirmingDisable = false }
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Turn off", role: .destructive) { model.uninstall() }
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
        Button("Quit") { model.quit() }
            .buttonStyle(QuietButtonStyle())
            .help(Text("Quits the app. The limit stays on."))
    }
}
