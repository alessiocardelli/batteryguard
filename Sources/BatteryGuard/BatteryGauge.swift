import SwiftUI

/// Batteria scheumorfica: guscio di vetro, energia arancione alla carica attuale, tacca incisa alla soglia.
/// `percent` nil disegna la batteria spenta (vetro senza energia), `limit` nil nasconde la tacca.
/// Solo disegno: l'interazione sulla soglia sta in `AdjustableBattery`, l'accessibilità in chi la usa.
struct BatteryGauge: View {
    let percent: Int?
    let limit: Int?
    let isCharging: Bool
    var isAdjusting = false
    var isFocused = false
    /// Oltre questa soglia la batteria non si può limitare: zona tratteggiata, visibile ma spenta.
    var lockedFrom: Int?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bodySize = CGSize(width: 236, height: 96)
    private static let wall: CGFloat = 6
    private static let gap: CGFloat = 3
    private static let energyRect = CGRect(origin: .zero, size: bodySize).insetBy(dx: wall + gap, dy: wall + gap)

    private var bodySize: CGSize { Self.bodySize }
    private let bodyRadius: CGFloat = 24
    private var wall: CGFloat { Self.wall }
    private var gap: CGFloat { Self.gap }
    private let terminalSize = CGSize(width: 9, height: 34)
    private let labelHeight: CGFloat = 16
    private let labelSpacing: CGFloat = 6

    private var cavityRect: CGRect { CGRect(origin: .zero, size: bodySize).insetBy(dx: wall, dy: wall) }
    private var energyRect: CGRect { Self.energyRect }
    private var cavityRadius: CGFloat { bodyRadius - wall }
    private var energyRadius: CGFloat { cavityRadius - gap }

    private var isDark: Bool { colorScheme == .dark }
    private var isHighContrast: Bool { contrast == .increased }

    var body: some View {
        VStack(spacing: labelSpacing) {
            if limit != nil {
                limitLabel
            }
            HStack(spacing: 2) {
                batteryBody
                terminal
            }
        }
    }

    // MARK: Geometria della soglia

    /// Ascissa della tacca nelle coordinate della vista (etichetta e corpo partono entrambi da x = 0).
    static func tickX(for value: Int) -> CGFloat {
        energyRect.minX + energyRect.width * CGFloat(min(max(value, 0), 100)) / 100
    }

    /// Valore in percento (non arrotondato) corrispondente a un'ascissa.
    static func value(atX x: CGFloat) -> Double {
        Double((x - energyRect.minX) / energyRect.width * 100)
    }

    private func tickX(for value: Int) -> CGFloat { Self.tickX(for: value) }

    // MARK: Etichetta della soglia

    private var thresholdAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: isAdjusting ? 0.1 : 0.18)
    }

    @ViewBuilder
    private var limitLabel: some View {
        let totalWidth = bodySize.width + 2 + terminalSize.width
        if let limit {
            (Text("max ").font(.system(size: 11, weight: .medium))
                + Text("\(limit)%").font(.system(size: 11, weight: .semibold)))
                .monospacedDigit()
                .foregroundStyle(isAdjusting ? Palette.ink : Palette.secondaryText(isDark: isDark, highContrast: isHighContrast))
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: labelHeight)
                // Mentre si regola l'etichetta diventa una pillola d'energia: dice cosa si sta muovendo
                .background(
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.energyTop, Palette.energyMid], startPoint: .top, endPoint: .bottom))
                        .opacity(isAdjusting ? 1 : 0)
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isAdjusting)
                .position(x: min(max(tickX(for: limit), 26), bodySize.width - 26), y: labelHeight / 2)
                .frame(width: totalWidth, height: labelHeight, alignment: .leading)
                .animation(thresholdAnimation, value: limit)
        } else {
            Color.clear.frame(width: totalWidth, height: labelHeight)
        }
    }

    // MARK: Guscio

    private var batteryBody: some View {
        let shape = RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
        return ZStack(alignment: .topLeading) {
            // Corpo di vetro: chiaro in alto, più denso in basso
            shape.fill(LinearGradient(
                colors: isDark
                    ? [Color.white.opacity(0.17), Color.white.opacity(0.06)]
                    : [Color.white.opacity(0.92), Color.white.opacity(0.45)],
                startPoint: .top, endPoint: .bottom
            ))

            cavity

            if let lockedFrom {
                lockedZone(from: lockedFrom)
            }

            if let percent {
                energy(percent: percent)
            }

            if let percent {
                chargeText(percent: percent)
            }

            if let limit {
                engravedTick(at: limit)
            }

            glassReflection

            // Bordo a doppio tono: filo scuro esterno, smusso chiaro interno
            shape.strokeBorder(Palette.outerEdge(isDark: isDark, highContrast: isHighContrast), lineWidth: isHighContrast ? 1.5 : 1)
            shape.inset(by: 1).strokeBorder(LinearGradient(
                colors: isDark
                    ? [Color.white.opacity(0.32), Color.white.opacity(0.04)]
                    : [Color.white, Color.white.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 1)

            if let limit {
                handle(at: limit)
            }
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .compositingGroup()
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.14), radius: 6, y: 3)
        .shadow(color: Color.black.opacity(isDark ? 0.3 : 0.08), radius: 1, y: 0.5)
        .overlay(
            // Anello di fuoco da tastiera attorno al corpo, fuori dal gruppo per non prendere l'ombra
            shape
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .padding(-4)
                .opacity(isFocused ? 1 : 0)
        )
    }

    /// Tratteggio sotto l'energia: si vede solo sul vetro vuoto, se la carica supera la soglia sparisce sotto l'arancione.
    private func lockedZone(from value: Int) -> some View {
        let start = tickX(for: value)
        let zone = CGRect(x: start, y: energyRect.minY, width: energyRect.maxX - start, height: energyRect.height)
        let color = isHighContrast
            ? Color.primary.opacity(0.35)
            : (isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.07))
        return Path { path in
            var x = zone.minX - zone.height
            while x < zone.maxX {
                path.move(to: CGPoint(x: x, y: zone.maxY))
                path.addLine(to: CGPoint(x: x + zone.height, y: zone.minY))
                x += 7
            }
        }
        .stroke(color, lineWidth: 1.5)
        .mask(
            ZStack(alignment: .topLeading) {
                Color.clear
                Rectangle()
                    .frame(width: zone.width, height: zone.height)
                    .offset(x: zone.minX, y: zone.minY)
            }
        )
        .mask(
            RoundedRectangle(cornerRadius: energyRadius, style: .continuous)
                .frame(width: energyRect.width, height: energyRect.height)
                .offset(x: energyRect.minX, y: energyRect.minY)
                .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        )
        .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Carica scritta nella batteria

    /// Posizione fissa a sinistra: non incrocia mai la tacca (che parte dal 50%) e non salta quando la carica cambia.
    /// Il testo è disegnato due volte e ritagliato sul fronte dell'energia: inchiostro scuro sull'arancione,
    /// colore del testo sul vetro vuoto. Così a carica bassa resta leggibile senza spostarsi.
    private func chargeText(percent: Int) -> some View {
        let level = CGFloat(min(max(percent, 0), 100)) / 100
        let front = energyRect.minX + energyRect.width * level
        let label = (Text("\(percent)").font(.system(size: 34, weight: .semibold, design: .rounded))
            + Text("%").font(.system(size: 20, weight: .semibold, design: .rounded)))
            .fixedSize()
            .padding(.leading, energyRect.minX + 14)
            .frame(width: bodySize.width, height: bodySize.height, alignment: .leading)
        let glassText = isHighContrast ? Color.primary : (isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.78))

        return ZStack(alignment: .topLeading) {
            label
                .foregroundStyle(glassText)
                .mask(alignment: .leading) {
                    Rectangle().padding(.leading, front).frame(width: bodySize.width)
                }
            label
                .foregroundStyle(Palette.ink)
                // Filo di luce sotto le cifre: le incide nell'energia invece di appoggiarle sopra
                .shadow(color: Color.white.opacity(isHighContrast ? 0 : 0.35), radius: 0, y: 0.5)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: front)
                }
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: percent)
        .allowsHitTesting(false)
    }

    private var cavity: some View {
        RoundedRectangle(cornerRadius: cavityRadius, style: .continuous)
            .fill(
                (isDark ? Color.black.opacity(0.38) : Color.black.opacity(0.06))
                    .shadow(.inner(color: Color.black.opacity(isDark ? 0.7 : 0.22), radius: 3, y: 1.5))
            )
            .frame(width: cavityRect.width, height: cavityRect.height)
            .offset(x: cavityRect.minX, y: cavityRect.minY)
    }

    // MARK: Energia

    private func energy(percent: Int) -> some View {
        let level = CGFloat(min(max(percent, 0), 100)) / 100
        let width = energyRect.width * level
        let shape = RoundedRectangle(cornerRadius: energyRadius, style: .continuous)

        return ZStack(alignment: .topLeading) {
            // Bagliore che si allarga nel vetro vuoto, contenuto nella cavità
            EnergyGlow(width: width, height: energyRect.height, radius: energyRadius, isAnimated: isAnimated)
                .offset(x: energyRect.minX, y: energyRect.minY)

            ZStack(alignment: .topLeading) {
                shape.fill(
                    LinearGradient(stops: [
                        .init(color: Palette.energyTop, location: 0),
                        .init(color: Palette.energyMid, location: 0.5),
                        .init(color: Palette.energyBottom, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .shadow(.inner(color: Palette.energyShade.opacity(0.55), radius: 5, y: -3))
                )

                // Luce interna che nasce dal fronte dell'energia
                RadialGradient(
                    colors: [Palette.energyCore.opacity(0.32), Palette.energyCore.opacity(0)],
                    center: UnitPoint(x: max(level - 0.04, 0.001), y: 0.5),
                    startRadius: 0, endRadius: 64
                )
                .blendMode(.screen)

                // Base più profonda a sinistra: dà verso al flusso
                LinearGradient(colors: [Palette.energyShade.opacity(0.12), .clear], startPoint: .leading, endPoint: UnitPoint(x: 0.5, y: 0.5))
                    .blendMode(.multiply)

                if isAnimated {
                    ChargingSheen(height: energyRect.height)
                }
            }
            .frame(width: energyRect.width, height: energyRect.height)
            .mask(alignment: .leading) { Rectangle().frame(width: width) }
            .offset(x: energyRect.minX, y: energyRect.minY)

            // Pelo del riempimento: filo di luce sul fronte
            if percent > 2 && percent < 99 {
                Meniscus(height: energyRect.height)
                    .offset(x: energyRect.minX + width - 1.5, y: energyRect.minY)
            }
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        .mask(
            RoundedRectangle(cornerRadius: energyRadius, style: .continuous)
                .frame(width: energyRect.width, height: energyRect.height)
                .offset(x: energyRect.minX, y: energyRect.minY)
                .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: percent)
    }

    private var isAnimated: Bool { isCharging && !reduceMotion }

    // MARK: Tacca incisa

    private func engravedTick(at value: Int) -> some View {
        let x = tickX(for: value)
        return ZStack(alignment: .topLeading) {
            // Incisione: solco scuro con il suo riflesso chiaro accanto
            Rectangle()
                .fill(isDark ? Color.black.opacity(0.75) : Color.black.opacity(isHighContrast ? 0.85 : 0.6))
                .frame(width: 1.5, height: cavityRect.height + wall * 2 - 4)
                .offset(x: x - 0.75, y: 2)
            Rectangle()
                .fill(Color.white.opacity(isDark ? 0.55 : 0.9))
                .frame(width: 1, height: cavityRect.height + wall * 2 - 4)
                .offset(x: x + 0.75, y: 2)
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        .animation(thresholdAnimation, value: value)
    }

    /// Maniglia sottile a metà tacca: dice che la soglia si afferra e si trascina.
    private func handle(at value: Int) -> some View {
        let size = CGSize(width: 8, height: 30)
        let shape = Capsule()
        return shape
            .fill(LinearGradient(
                colors: isAdjusting ? [Color(white: 0.95), Color(white: 0.86)] : [Color.white, Color(white: 0.91)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(shape.strokeBorder(Color.black.opacity(isHighContrast ? 0.6 : (isDark ? 0.4 : 0.18)), lineWidth: 0.5))
            .overlay(
                // Due righe di presa, come sulle maniglie dei controlli di sistema
                VStack(spacing: 2) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(Color.black.opacity(0.22)).frame(width: 3, height: 1)
                    }
                }
            )
            .frame(width: size.width, height: size.height)
            .scaleEffect(isAdjusting ? 1.12 : 1)
            .shadow(color: Color.black.opacity(isDark ? 0.55 : 0.28), radius: isAdjusting ? 3 : 2, y: 1)
            .position(x: tickX(for: value), y: bodySize.height / 2)
            .frame(width: bodySize.width, height: bodySize.height)
            .animation(thresholdAnimation, value: value)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isAdjusting)
            .allowsHitTesting(false)
    }

    // MARK: Riflesso del vetro

    private var glassReflection: some View {
        ZStack(alignment: .topLeading) {
            // Riflesso speculare sulla parte alta, sfumato ai lati per non sembrare un secondo riquadro
            RoundedRectangle(cornerRadius: cavityRadius - 3, style: .continuous)
                .fill(LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(isDark ? 0.22 : 0.42), location: 0),
                        .init(color: Color.white.opacity(isDark ? 0.05 : 0.1), location: 0.55),
                        .init(color: Color.white.opacity(0), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: cavityRect.width - 10, height: cavityRect.height * 0.4)
                .mask(LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                ))
                .offset(x: cavityRect.minX + 5, y: cavityRect.minY + 2)

            // Filo di luce netto vicino al bordo alto
            Capsule()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0), Color.white.opacity(isDark ? 0.5 : 0.85), Color.white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: cavityRect.width - 40, height: 1.5)
                .offset(x: cavityRect.minX + 20, y: cavityRect.minY + 4)
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: Polo positivo

    private var terminal: some View {
        let shape = UnevenTerminalShape()
        return ZStack {
            // Volume cilindrico: luce in alto, ombra sotto
            shape.fill(LinearGradient(stops: [
                .init(color: isDark ? Color.white.opacity(0.42) : Color.white, location: 0),
                .init(color: isDark ? Color.white.opacity(0.16) : Color(white: 0.82), location: 0.45),
                .init(color: isDark ? Color.white.opacity(0.06) : Color(white: 0.66), location: 1)
            ], startPoint: .top, endPoint: .bottom))
            shape.stroke(Palette.outerEdge(isDark: isDark, highContrast: isHighContrast), lineWidth: isHighContrast ? 1.5 : 1)
        }
        .frame(width: terminalSize.width, height: terminalSize.height)
        .shadow(color: Color.black.opacity(isDark ? 0.4 : 0.12), radius: 2, y: 1)
    }
}

/// Polo: lato sinistro dritto contro il corpo, lato destro arrotondato.
private struct UnevenTerminalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width * 0.8, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 1))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY + 1))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY + 1), tangent2End: CGPoint(x: rect.maxX, y: rect.midY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY - 1), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - 1), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
        path.closeSubpath()
        return path
    }
}

/// Alone dell'energia nel vetro vuoto. In carica respira lentamente.
private struct EnergyGlow: View {
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    let isAnimated: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        if isAnimated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                glow(intensity: 0.75 + 0.25 * sin(t * 2 * .pi / 3.2))
            }
        } else {
            glow(intensity: 0.75)
        }
    }

    private func glow(intensity: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isDark ? Palette.energyMid : Palette.energyTop)
                .frame(width: max(width, 1), height: height)
                .blur(radius: isDark ? 9 : 6)
                .opacity((isDark ? 0.7 : 0.5) * intensity)
            // Luce che filtra oltre il fronte, nel vetro ancora vuoto
            // Solo al buio: sul vetro chiaro la stessa luce diventa una macchia
            if isDark {
                Ellipse()
                    .fill(Palette.energyMid)
                    .frame(width: 26, height: height * 0.85)
                    .blur(radius: 8)
                    .opacity(0.5 * intensity)
                    .blendMode(.plusLighter)
                    .offset(x: width - 13)
            }
        }
        .frame(width: max(width, 1), height: height, alignment: .leading)
    }
}

/// Riflesso che scorre lento lungo l'energia mentre carica.
private struct ChargingSheen: View {
    let height: CGFloat
    private let period: Double = 4.2
    private let travel: Double = 2.6

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
                let progress = min(t / travel, 1)
                let eased = progress * progress * (3 - 2 * progress)
                let bandWidth: CGFloat = 70
                LinearGradient(
                    colors: [Color.white.opacity(0), Color.white.opacity(0.3), Color.white.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: bandWidth, height: height * 1.8)
                .rotationEffect(.degrees(14))
                .frame(height: height)
                .offset(x: -bandWidth + (proxy.size.width + bandWidth * 2) * eased)
                .opacity(progress < 1 ? 1 : 0)
                .blendMode(.screen)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Fronte del liquido: linea chiara con alone, più luminosa al centro.
private struct Meniscus: View {
    let height: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Palette.energyCore)
                .frame(width: 6, height: height)
                .blur(radius: 3)
                .opacity(0.55)
            Rectangle()
                .fill(LinearGradient(
                    colors: [Palette.energyCore.opacity(0.35), Color.white.opacity(0.95), Palette.energyCore.opacity(0.35)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: 1.5, height: height)
        }
        .frame(width: 3, height: height)
        .allowsHitTesting(false)
    }
}
