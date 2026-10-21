import SwiftUI

/// Slider della soglia: traccia incassata, energia fino al valore, tacche ogni passo, pomello da controllo di sistema.
/// Stessa semantica di `Slider`: `onEditingChanged(true)` all'inizio del trascinamento, `false` alla fine;
/// da tastiera e VoiceOver cambia solo il valore.
struct LimitSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private let knobSize: CGFloat = 20
    private let trackHeight: CGFloat = 6
    private let controlHeight: CGFloat = 24

    private var isDark: Bool { colorScheme == .dark }
    private var isHighContrast: Bool { contrast == .increased }
    private var stepCount: Int { Int(((range.upperBound - range.lowerBound) / step).rounded()) }
    private var fraction: CGFloat { CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let travel = proxy.size.width - knobSize
                let knobX = knobSize / 2 + travel * fraction

                ZStack(alignment: .leading) {
                    track
                    energy(width: knobX)
                    ticks(travel: travel)
                    knob
                        .offset(x: knobX - knobSize / 2)
                }
                .frame(height: controlHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !isDragging {
                                isDragging = true
                                onEditingChanged(true)
                            }
                            setValue(atX: drag.location.x, travel: travel)
                        }
                        .onEnded { drag in
                            setValue(atX: drag.location.x, travel: travel)
                            isDragging = false
                            onEditingChanged(false)
                        }
                )
            }
            .frame(height: controlHeight)

            HStack {
                Text("\(Int(range.lowerBound))%")
                Spacer()
                Text("\(Int(range.upperBound))%")
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.secondaryText(isDark: isDark, highContrast: isHighContrast))
        }
        .onHover { isHovering = $0 }
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: nudge(by: -1)
            case .right, .up: nudge(by: 1)
            @unknown default: break
            }
        }
        // Per VoiceOver è uno slider di sistema a tutti gli effetti: ruolo, valore, incremento e decremento
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step) {
                Text(label)
            }
            .accessibilityValue("\(Int(value.rounded()))%")
        }
    }

    private func setValue(atX x: CGFloat, travel: CGFloat) {
        guard travel > 0 else { return }
        let ratio = min(max((x - knobSize / 2) / travel, 0), 1)
        let steps = (Double(ratio) * Double(stepCount)).rounded()
        let newValue = range.lowerBound + steps * step
        if newValue != value { value = newValue }
    }

    private func nudge(by steps: Int) {
        let newValue = min(max(value + Double(steps) * step, range.lowerBound), range.upperBound)
        if newValue != value { value = newValue }
    }

    // MARK: Parti

    private var track: some View {
        Capsule()
            .fill(
                (isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.09))
                    .shadow(.inner(color: Color.black.opacity(isDark ? 0.6 : 0.2), radius: 1.5, y: 1))
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(isDark ? 0.08 : 0.6), lineWidth: 0.5)
            )
            .overlay(
                Capsule().strokeBorder(Palette.outerEdge(isDark: isDark, highContrast: isHighContrast), lineWidth: isHighContrast ? 1 : 0)
            )
            .frame(height: trackHeight)
    }

    private func energy(width: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [Palette.energyTop, Palette.energyMid, Palette.energyBottom],
                    startPoint: .top, endPoint: .bottom
                )
                .shadow(.inner(color: Color.white.opacity(0.45), radius: 0.5, y: 0.5))
            )
            .frame(width: width, height: trackHeight)
            .shadow(color: Palette.energyMid.opacity(isDark ? 0.55 : 0.35), radius: 4)
    }

    private func ticks(travel: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0...stepCount, id: \.self) { index in
                let isFilled = CGFloat(index) / CGFloat(stepCount) <= fraction + 0.0001
                Capsule()
                    .fill(isFilled
                          ? Color.white.opacity(0.75)
                          : (isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.22)))
                    .frame(width: 1.5, height: 2)
                    .offset(x: knobSize / 2 + travel * CGFloat(index) / CGFloat(stepCount) - 0.75)
            }
        }
        .allowsHitTesting(false)
    }

    private var knob: some View {
        let isPressed = isDragging
        return Circle()
            .fill(LinearGradient(
                colors: isPressed
                    ? [Color(white: 0.93), Color(white: 0.86)]
                    : [Color.white, Color(white: 0.94)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(Circle().strokeBorder(Color.black.opacity(isDark ? 0.35 : 0.14), lineWidth: 0.5))
            .overlay(
                // Anello di fuoco visibile da tastiera
                Circle()
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-4)
                    .opacity(isFocused ? 1 : 0)
            )
            .frame(width: knobSize, height: knobSize)
            .shadow(color: Color.black.opacity(isDark ? 0.5 : 0.22), radius: isPressed ? 1.5 : 2.5, y: 1)
            .shadow(color: Color.black.opacity(0.12), radius: 0.5, y: 0.5)
            .scaleEffect(isHovering && !isPressed ? 1.04 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
