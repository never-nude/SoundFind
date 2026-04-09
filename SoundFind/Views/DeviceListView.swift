import SwiftUI

/// Bottom sheet listing every device we've ever seen, with a section for
/// "In range right now" pulled directly from the live BluetoothManager.
struct DeviceListView: View {
    let storedRows: [DeviceViewModel.Row]
    let liveDevices: [UUID: DiscoveredDevice]
    let stableOrder: [UUID]
    let isDebugMode: Bool
    let onSelect: (UUID) -> Void
    let onIdentify: (UUID) -> Void
    let onFavorite: (UUID) -> Void
    let onForget: (UUID) -> Void

    /// Uses the manager's stable order so rows don't reshuffle on every
    /// advertisement. Anything that hasn't been placed yet (brand-new
    /// devices that arrived after the last tick) falls to the bottom.
    private var liveSorted: [DiscoveredDevice] {
        var seen = Set<UUID>()
        var out: [DiscoveredDevice] = []
        for id in stableOrder {
            if let d = liveDevices[id] {
                out.append(d)
                seen.insert(id)
            }
        }
        for (id, d) in liveDevices where !seen.contains(id) {
            out.append(d)
        }
        return out
    }

    private var offlineRows: [DeviceViewModel.Row] {
        let liveIDs = Set(liveDevices.keys)
        return storedRows.filter { !liveIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !liveSorted.isEmpty {
                    Section(isDebugMode ? "All BLE Devices (tap to identify)" : "In Range") {
                        ForEach(liveSorted) { device in
                            DeviceRow(
                                name: device.name,
                                subtitle: subtitle(for: device),
                                icon: iconForProbe(device),
                                accent: Color(band: device.proximityBand),
                                trailing: ProximityDot(proximity: device.proximity)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isDebugMode {
                                    onIdentify(device.id)
                                } else {
                                    onSelect(device.id)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { onForget(device.id) } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                                Button { onFavorite(device.id) } label: {
                                    Label("Favorite", systemImage: "star")
                                }.tint(.yellow)
                                Button { onIdentify(device.id) } label: {
                                    Label("Identify", systemImage: "magnifyingglass")
                                }.tint(.blue)
                            }
                        }
                    }
                }

                if !offlineRows.isEmpty {
                    Section("Seen Before") {
                        ForEach(offlineRows) { row in
                            Button { onSelect(row.id) } label: {
                                DeviceRow(
                                    name: row.name,
                                    subtitle: relativeString(row.lastSeen),
                                    icon: row.isFavorite ? "star.fill" : "headphones",
                                    accent: .secondary,
                                    trailing: EmptyView()
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { onForget(row.id) } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                                Button { onFavorite(row.id) } label: {
                                    Label(row.isFavorite ? "Unfavorite" : "Favorite",
                                          systemImage: row.isFavorite ? "star.slash" : "star")
                                }.tint(.yellow)
                            }
                        }
                    }
                }

                if liveSorted.isEmpty && offlineRows.isEmpty {
                    ContentUnavailableView(
                        "No Soundcore devices yet",
                        systemImage: "headphones",
                        description: Text("Start scanning and we'll list every Soundcore device we see nearby.")
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func relativeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Seen " + formatter.localizedString(for: date, relativeTo: .now)
    }

    /// Builds the per-row subtitle shown under each live device. In normal mode
    /// the user sees "~12 ft · Getting warmer". In debug mode we also surface
    /// the raw dBm and the manufacturer company ID (2-byte prefix) so Anker
    /// devices (`0x049A`) can be spotted even when they advertise nameless.
    private func subtitle(for device: DiscoveredDevice) -> String {
        var parts: [String] = [device.distanceLabel, device.proximityBand.label]
        if isDebugMode {
            parts.append("\(device.rssi) dBm")
            if let mfg = device.manufacturerData, mfg.count >= 2 {
                let companyID = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
                parts.append(String(format: "co 0x%04X", companyID))
            }
        }
        switch device.probeState {
        case .idle: break
        case .connecting: parts.append("connecting…")
        case .discovered: parts.append("probed ✓")
        case .failed(let msg): parts.append("✗ \(msg)")
        }
        return parts.joined(separator: " · ")
    }

    private func iconForProbe(_ device: DiscoveredDevice) -> String {
        switch device.probeState {
        case .connecting: return "arrow.triangle.2.circlepath"
        case .discovered: return "checkmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .idle:       return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Row

private struct DeviceRow<Trailing: View>: View {
    let name: String
    let subtitle: String
    let icon: String
    let accent: Color
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 4)
    }
}

private struct ProximityDot: View {
    let proximity: Double
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [.blue, .orange, .red],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(width: 46, height: 6)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .offset(x: (proximity - 0.5) * 46),
                alignment: .center
            )
    }
}

private extension Color {
    init(band: ProximityBand) {
        switch band {
        case .cold: self = .blue
        case .warm: self = .orange
        case .hot:  self = .red
        }
    }
}
