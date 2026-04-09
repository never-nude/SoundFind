import SwiftUI

/// Find My-inspired tracking UI. A single huge pulsing orb dominates the
/// screen; it scales up and warms in color as you get closer to the target
/// device. Below the orb, a qualitative label ("Very Close", "Near", "Far",
/// "Very Far") communicates proximity in plain language, and — only if the
/// device has been calibrated — a subtler distance number is shown in feet.
///
/// The continuous haptic loop lives on the caller (DeviceDetailView), so this
/// view is purely visual.
struct RadarView: View {
    /// [0, 1] — 1 means touching. Driven from DiscoveredDevice.proximity.
    let proximity: Double
    /// Human-readable distance. Only shown when the device is calibrated.
    let distanceLabel: String
    /// If false, the view hides the distance number and shows an "Uncalibrated"
    /// hint instead, to avoid making up numbers the user will trust.
    let isCalibrated: Bool
    let deviceName: String

    @State private var ringPulse: CGFloat = 0.9
    @State private var innerPulse: CGFloat = 0.95

    var body: some View {
        VStack(spacing: 28) {
            titleView
            orb
            qualitativeLabel
            if isCalibrated {
                Text(distanceLabel)
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(bandColor)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.4), value: distanceLabel)
            } else {
                uncalibratedHint
            }
        }
        .onAppear {
            startAnimations()
        }
    }

    // MARK: - Subviews

    private var titleView: some View {
        Text(deviceName)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    /// The bullseye. Grows in size AND gradient intensity as the device gets
    /// closer. Two slow-pulsing concentric rings give the "active tracking"
    /// feeling Apple's UI has.
    private var orb: some View {
        GeometryReader { geo in
            let maxSide = min(geo.size.width, geo.size.height)
            // Base scale: from 35% (very far) up to 105% (touching).
            let baseScale = 0.35 + proximity * 0.70
            let size = maxSide * baseScale

            ZStack {
                // Outer pulse — the slow "radar ping" shell.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [bandColor.opacity(0.55), bandColor.opacity(0)],
                            center: .center,
                            startRadius: size * 0.15,
                            endRadius: size * 0.9
                        )
                    )
                    .frame(width: size * 1.8, height: size * 1.8)
                    .scaleEffect(ringPulse)
                    .opacity(0.9 - Double(ringPulse - 0.9) * 1.2)
                    .blur(radius: 12)

                // Mid glow — constant size, breathing opacity so there's
                // always SOMETHING reacting even when you stop moving.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [bandColor.opacity(0.9), bandColor.opacity(0.05)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.6
                        )
                    )
                    .frame(width: size, height: size)
                    .scaleEffect(innerPulse)

                // Core — hard-edged filled circle with the active color.
                Circle()
                    .fill(bandColor)
                    .frame(width: size * 0.25, height: size * 0.25)
                    .overlay(
                        Image(systemName: "headphones")
                            .font(.system(size: size * 0.11, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: bandColor.opacity(0.6), radius: size * 0.15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.8), value: proximity)
        }
        .frame(height: 360)
    }

    private var qualitativeLabel: some View {
        Text(qualitativeText)
            .font(.title.weight(.bold))
            .foregroundStyle(bandColor)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: qualitativeText)
    }

    private var uncalibratedHint: some View {
        VStack(spacing: 4) {
            Text("Uncalibrated")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.secondary.opacity(0.15), in: Capsule())
            Text("Tap Calibrate below for accurate distance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    private var bandColor: Color {
        switch proximity {
        case 0.85...:    return .red
        case 0.60..<0.85: return .orange
        case 0.35..<0.60: return .yellow
        case 0.15..<0.35: return .cyan
        default:         return .blue
        }
    }

    private var qualitativeText: String {
        switch proximity {
        case 0.85...:    return "Very Close"
        case 0.60..<0.85: return "Near"
        case 0.35..<0.60: return "Warm"
        case 0.15..<0.35: return "Far"
        default:         return "Very Far"
        }
    }

    private func startAnimations() {
        // Slow outer ping — decoupled from proximity so there's always motion.
        withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
            ringPulse = 1.35
        }
        // Gentle "breathing" on the inner glow.
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            innerPulse = 1.10
        }
    }
}
