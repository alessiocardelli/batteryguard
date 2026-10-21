import SwiftUI

/// CTA principale: energia arancione con inchiostro scuro, luce in alto, si abbassa quando premuta.
struct EnergyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        EnergyButton(configuration: configuration)
    }

    private struct EnergyButton: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    shape.fill(
                        LinearGradient(
                            colors: [Palette.energyTop, Palette.energyMid],
                            startPoint: .top, endPoint: .bottom
                        )
                        .shadow(.inner(color: Color.white.opacity(pressed ? 0.15 : 0.55), radius: 0.5, y: 1))
                        .shadow(.inner(color: Palette.energyShade.opacity(0.35), radius: 2, y: -1))
                    )
                )
                .overlay(shape.fill(Color.white.opacity(isHovering && !pressed ? 0.1 : 0)))
                .overlay(shape.fill(Palette.energyShade.opacity(pressed ? 0.14 : 0)))
                .overlay(shape.strokeBorder(Palette.energyShade.opacity(colorScheme == .dark ? 0.6 : 0.35), lineWidth: 0.5))
                .shadow(color: Palette.energyMid.opacity(pressed ? 0.15 : 0.35), radius: pressed ? 2 : 6, y: pressed ? 1 : 2)
                .opacity(isEnabled ? 1 : 0.6)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: pressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

/// Bottone pieno e compatto per la conferma distruttiva.
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.destructive.shadow(.inner(color: Color.white.opacity(0.3), radius: 0.5, y: 1)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0))
            )
            .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 1)
    }
}

/// Bottone di contorno sobrio (Annulla).
struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SubtleButton(configuration: configuration)
    }

    private struct SubtleButton: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovering ? 0.11 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .onHover { isHovering = $0 }
        }
    }
}

/// Azione discreta del footer: solo testo, alone leggero al passaggio del mouse.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        @State private var isHovering = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering
                                 ? Color.primary
                                 : Palette.secondaryText(isDark: colorScheme == .dark, highContrast: contrast == .increased))
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : isHovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}
