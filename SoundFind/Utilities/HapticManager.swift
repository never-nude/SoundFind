import Foundation
import UIKit
import CoreHaptics

/// Emits short haptic pulses whose intensity scales with proximity.
/// Uses CoreHaptics when available and falls back to UIImpactFeedbackGenerator.
@MainActor
final class HapticManager {

    static let shared = HapticManager()

    private var engine: CHHapticEngine?
    private var lastPulseAt: Date = .distantPast

    private init() {
        prepareEngine()
    }

    private func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
            engine?.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            engine?.stoppedHandler = { _ in }
        } catch {
            engine = nil
        }
    }

    /// Call this on every proximity update. The method throttles itself so
    /// callers don't need to worry about over-pulsing.
    /// - Parameter proximity: value in [0, 1], closer to 1 means closer device.
    func pulse(forProximity proximity: Double) {
        let clamped = max(0, min(1, proximity))

        // Period scales from 900ms (far) to 120ms (very close).
        let period = 0.9 - (0.78 * clamped)
        let now = Date()
        guard now.timeIntervalSince(lastPulseAt) >= period else { return }
        lastPulseAt = now

        if let engine {
            playCoreHaptic(intensity: Float(0.3 + 0.7 * clamped),
                           sharpness: Float(0.4 + 0.6 * clamped),
                           engine: engine)
        } else {
            let style: UIImpactFeedbackGenerator.FeedbackStyle =
                clamped > 0.66 ? .heavy : clamped > 0.33 ? .medium : .light
            UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: CGFloat(clamped))
        }
    }

    private func playCoreHaptic(intensity: Float, sharpness: Float, engine: CHHapticEngine) {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // Silent fallback — if CoreHaptics fails mid-run, we'll just skip this pulse.
        }
    }
}
