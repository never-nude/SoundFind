import SwiftUI
import SwiftData
import MapKit

/// Full-screen detail view for a specific device. Shows the radar when the
/// device is in range, and the last known map location when it isn't.
/// Offers a "Play Sound" button that attempts a GATT write.
struct DeviceDetailView: View {
    let deviceID: UUID

    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var location: LocationManager
    @Environment(\.dismiss) private var dismiss

    @Query private var stored: [StoredDevice]
    @State private var calibrationFeet: Double = 3
    @State private var calibrateFlashUntil: Date = .distantPast

    init(deviceID: UUID) {
        self.deviceID = deviceID
        let predicate = #Predicate<StoredDevice> { $0.id == deviceID }
        _stored = Query(filter: predicate)
    }

    private var liveDevice: DiscoveredDevice? {
        bluetooth.discovered[deviceID]
    }

    private var storedDevice: StoredDevice? {
        stored.first
    }

    private var displayName: String {
        liveDevice?.name ?? storedDevice?.name ?? "Unknown device"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let liveDevice {
                        RadarView(
                            proximity: liveDevice.proximity,
                            distanceLabel: liveDevice.distanceLabel,
                            isCalibrated: liveDevice.isCalibrated,
                            deviceName: displayName
                        )
                        .padding(.top, 32)
                    } else {
                        outOfRangeSection
                    }

                    actionButtons

                    if let stored = storedDevice {
                        metadataSection(stored: stored)
                    }
                }
                .padding()
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        bluetooth.focusedDeviceID = nil
                        dismiss()
                    }
                }
            }
        }
        .onAppear  { bluetooth.focusedDeviceID = deviceID }
        .onDisappear { bluetooth.focusedDeviceID = nil }
    }

    // MARK: - Sections

    private var outOfRangeSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Out of range")
                .font(.title3.weight(.semibold))
            if let stored = storedDevice, stored.lastCoordinate != nil {
                Text("Last seen \(stored.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                lastKnownMap(stored: stored)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                Text("We never captured a GPS fix for this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 32)
    }

    @ViewBuilder
    private func lastKnownMap(stored: StoredDevice) -> some View {
        if let coord = stored.lastCoordinate {
            let region = MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            )
            Map(initialPosition: .region(region)) {
                Marker(stored.name, systemImage: "headphones", coordinate: coord)
                    .tint(.orange)
            }
            .mapStyle(.standard(elevation: .realistic))
            .allowsHitTesting(false)
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 16) {
            calibrationCard
            Button {
                bluetooth.playSound(on: deviceID)
            } label: {
                Label("Play Sound", systemImage: "speaker.wave.3.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(liveDevice == nil)

            if liveDevice == nil {
                Text("The device must be in range to play a sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Calibration control. Lets the user teach SoundFind this device's
    /// actual RSSI reference by standing a known distance away and tapping
    /// Calibrate. Only enabled when the device is in range.
    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: liveDevice?.isCalibrated == true
                      ? "checkmark.seal.fill" : "target")
                    .foregroundStyle(liveDevice?.isCalibrated == true ? .green : .blue)
                Text("Calibration")
                    .font(.headline)
                Spacer()
                if liveDevice?.isCalibrated == true {
                    Button("Reset") { bluetooth.clearCalibration(deviceID: deviceID) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            Text("Stand the phone this far from the device, then tap Calibrate. SoundFind will remember the reference so future distance readings are accurate for this pair of headphones.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Distance")
                    .font(.subheadline)
                Spacer()
                Text("\(Int(calibrationFeet)) ft")
                    .font(.headline.monospacedDigit())
                Stepper("", value: $calibrationFeet, in: 1...15, step: 1)
                    .labelsHidden()
            }

            Button {
                bluetooth.calibrate(deviceID: deviceID, atFeet: calibrationFeet)
                calibrateFlashUntil = .now.addingTimeInterval(2)
            } label: {
                Label(
                    calibrateFlashUntil > .now ? "Calibrated ✓" : "Calibrate",
                    systemImage: "target"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(calibrateFlashUntil > .now ? .green : .blue)
            .disabled(liveDevice == nil)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func metadataSection(stored: StoredDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details")
                .font(.headline)
            row("First seen", stored.firstSeen.formatted(date: .abbreviated, time: .shortened))
            row("Last seen",  stored.lastSeen.formatted(date: .abbreviated, time: .shortened))
            row("Last RSSI",  "\(stored.lastRSSI) dBm")
            if let coord = stored.lastCoordinate {
                row("Coordinates", String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
            }
            row("ID", stored.id.uuidString)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}
