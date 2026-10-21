import SwiftUI

/// Batteria disegnata: riempimento alla carica attuale, tacca con etichetta alla soglia massima.
struct BatteryGauge: View {
    let percent: Int
    let limit: Int
    let isCharging: Bool

    private let bodySize = CGSize(width: 208, height: 80)
    private let inset: CGFloat = 6
    private let labelHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            VStack(spacing: 4) {
                limitLabel
                batteryBody
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.35))
                .frame(width: 6, height: 28)
                .padding(.bottom, (bodySize.height - 28) / 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Batteria al \(percent)%, ricarica massima \(limit)%")
    }

    private var innerWidth: CGFloat { bodySize.width - inset * 2 }

    private func xPosition(for value: Int) -> CGFloat {
        inset + innerWidth * CGFloat(min(max(value, 0), 100)) / 100
    }

    private var limitLabel: some View {
        Text("max \(limit)%")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .fixedSize()
            .position(x: min(max(xPosition(for: limit), 26), bodySize.width - 26), y: labelHeight / 2)
            .frame(width: bodySize.width, height: labelHeight)
    }

    private var batteryBody: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 3)

            RoundedRectangle(cornerRadius: 8)
                .fill(fillColor)
                .frame(width: max(innerWidth * CGFloat(percent) / 100, 0), height: bodySize.height - inset * 2)
                .offset(x: inset, y: inset)

            // Bordo nel colore dello sfondo: la tacca resta visibile anche sopra il riempimento
            Rectangle()
                .fill(Color.primary)
                .frame(width: 2, height: bodySize.height + 8)
                .padding(.horizontal, 1.5)
                .background(Color(nsColor: .windowBackgroundColor))
                .offset(x: xPosition(for: limit) - 2.5, y: -4)
        }
        .frame(width: bodySize.width, height: bodySize.height)
    }

    private var fillColor: Color {
        if isCharging { return .green }
        if percent <= 20 { return .red }
        return Color.primary.opacity(0.7)
    }
}
