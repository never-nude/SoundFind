import Foundation
import Observation
import Combine
import CoreLocation
import SwiftData

/// Bridges the BluetoothManager + LocationManager with the SwiftData store.
///
/// Responsibilities:
///   - Persist any Soundcore device the first time it's seen.
///   - Update `lastSeen`, `lastRSSI`, and last known GPS on subsequent sightings.
///   - Expose a list of stored device rows for the UI.
///
/// Uses the iOS 17 `@Observable` macro so the view can create it lazily from
/// `.task` once `@Environment(\.modelContext)` is available — avoiding the
/// need for a placeholder ModelContainer at init time.
@Observable
@MainActor
final class DeviceViewModel {

    struct Row: Identifiable, Hashable {
        let id: UUID
        let name: String
        let isInRange: Bool
        let rssi: Int?
        let proximity: Double?
        let lastSeen: Date
        let lastCoordinate: CLLocationCoordinate2D?
        let isFavorite: Bool

        static func == (lhs: Row, rhs: Row) -> Bool { lhs.id == rhs.id && lhs.lastSeen == rhs.lastSeen }
        func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(lastSeen) }
    }

    var rows: [Row] = []

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(context: ModelContext) {
        self.context = context
        reload()
    }

    /// Wire up Combine subscriptions so the view model reacts to every new
    /// advertisement the BluetoothManager publishes.
    func bind(bluetooth: BluetoothManager, location: LocationManager) {
        bluetooth.$discovered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] discovered in
                guard let self else { return }
                self.mergeDiscoveries(discovered, location: location.currentCoordinate())
                self.reload()
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence

    private func mergeDiscoveries(_ discovered: [UUID: DiscoveredDevice], location coord: CLLocationCoordinate2D?) {
        for (id, device) in discovered {
            let fetch = FetchDescriptor<StoredDevice>(predicate: #Predicate { $0.id == id })
            let existing = (try? context.fetch(fetch))?.first

            if let existing {
                existing.name = device.name
                existing.lastSeen = device.lastSeen
                existing.lastRSSI = device.rssi
                if let coord {
                    existing.lastLatitude = coord.latitude
                    existing.lastLongitude = coord.longitude
                    existing.lastLocationTimestamp = .now
                }
            } else {
                let new = StoredDevice(
                    id: id,
                    name: device.name,
                    firstSeen: .now,
                    lastSeen: device.lastSeen,
                    lastRSSI: device.rssi,
                    lastLatitude: coord?.latitude,
                    lastLongitude: coord?.longitude,
                    lastLocationTimestamp: coord == nil ? nil : .now,
                    isFavorite: false
                )
                context.insert(new)
            }
        }
        try? context.save()
    }

    func toggleFavorite(_ id: UUID) {
        let fetch = FetchDescriptor<StoredDevice>(predicate: #Predicate { $0.id == id })
        if let stored = (try? context.fetch(fetch))?.first {
            stored.isFavorite.toggle()
            try? context.save()
            reload()
        }
    }

    func forget(_ id: UUID) {
        let fetch = FetchDescriptor<StoredDevice>(predicate: #Predicate { $0.id == id })
        if let stored = (try? context.fetch(fetch))?.first {
            context.delete(stored)
            try? context.save()
            reload()
        }
    }

    // MARK: - Building rows

    private func reload() {
        let all = (try? context.fetch(FetchDescriptor<StoredDevice>())) ?? []
        rows = all
            .sorted { $0.lastSeen > $1.lastSeen }
            .map { stored in
                Row(
                    id: stored.id,
                    name: stored.name,
                    isInRange: false,
                    rssi: stored.lastRSSI,
                    proximity: nil,
                    lastSeen: stored.lastSeen,
                    lastCoordinate: stored.lastCoordinate,
                    isFavorite: stored.isFavorite
                )
            }
    }
}
