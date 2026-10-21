import AppKit
import SwiftUI

/// La batteria è il controllo della soglia: si trascina la tacca o si clicca in un punto del corpo,
/// a scatti di `step` dentro `range`. Da tastiera frecce, per VoiceOver elemento regolabile.
/// Stessa semantica di `Slider`: `onEditingChanged(true)` all'inizio del trascinamento, `false` al rilascio;
/// da tastiera e VoiceOver cambia solo il valore.
struct AdjustableBattery: View {
    let percent: Int
    let isCharging: Bool
    @Binding var limit: Double
    let range: ClosedRange<Int>
    let step: Int
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var isNearHandle = false
    @State private var hasUsedKeyboard = false
    @State private var keyMonitor: Any?
    @FocusState private var isFocused: Bool

    /// Distanza dalla tacca entro cui il puntatore "aggancia" la maniglia.
    private let handleReach: CGFloat = 12

    private var limitValue: Int { Int(limit.rounded()) }

    /// Con "Navigazione da tastiera" attiva l'anello segue il fuoco del Tab; altrimenti compare
    /// appena si usano le frecce, per dire quale controllo stanno regolando.
    private var showsFocusRing: Bool {
        isFocused || hasUsedKeyboard
    }

    var body: some View {
        BatteryGauge(
            percent: percent,
            limit: limitValue,
            isCharging: isCharging,
            isAdjusting: isDragging || isNearHandle,
            isFocused: showsFocusRing,
            lockedFrom: range.upperBound
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !isDragging {
                        isDragging = true
                        onEditingChanged(true)
                    }
                    NSCursor.resizeLeftRight.set()
                    setValue(atX: drag.location.x)
                }
                .onEnded { drag in
                    setValue(atX: drag.location.x)
                    isDragging = false
                    onEditingChanged(false)
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isNearHandle = abs(location.x - BatteryGauge.tickX(for: limitValue)) <= handleReach
                // Sulla maniglia si trascina, nel resto della batteria si clicca per spostare la soglia lì
                (isNearHandle || isDragging ? NSCursor.resizeLeftRight : NSCursor.pointingHand).set()
            case .ended:
                isNearHandle = false
                if !isDragging { NSCursor.arrow.set() }
            }
        }
        .focusable()
        .focused($isFocused)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
        // Per VoiceOver è uno slider di sistema: ruolo, incremento e decremento a passi di `step`.
        // Più solido di accessibilityAdjustableAction, che su macOS lascia l'elemento senza ruolo
        .accessibilityRepresentation {
            Slider(value: $limit, in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step)) {
                Text("Batteria al \(percent)%")
            }
            .accessibilityValue("soglia massima \(limitValue)%")
            .accessibilityHint("Da \(range.lowerBound) a \(range.upperBound)%. Trascina la tacca o usa le frecce per cambiarla")
        }
    }

    /// Frecce intercettate a livello di finestra: su macOS 13 una vista SwiftUI `focusable` riceve il fuoco
    /// solo con "Navigazione da tastiera" attiva, e la batteria è l'unico controllo regolabile del popover.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.isKeyWindow == true,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            switch event.keyCode {
            case 123, 125: nudge(by: -1)  // sinistra, giù
            case 124, 126: nudge(by: 1)   // destra, su
            default: return event
            }
            hasUsedKeyboard = true
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        hasUsedKeyboard = false
    }

    private func setValue(atX x: CGFloat) {
        let raw = BatteryGauge.value(atX: x)
        let snapped = Int((raw / Double(step)).rounded()) * step
        let newValue = min(max(snapped, range.lowerBound), range.upperBound)
        guard newValue != limitValue else { return }
        limit = Double(newValue)
        // Scatto percepibile sul trackpad Force Touch; altrove non fa nulla
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func nudge(by steps: Int) {
        let newValue = min(max(limitValue + steps * step, range.lowerBound), range.upperBound)
        if newValue != limitValue { limit = Double(newValue) }
    }
}
