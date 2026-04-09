import Foundation
import CoreBluetooth
import CoreLocation
import SwiftData

/// Transient state of a GATT probe attempt. Used by the debug "identify"
/// flow so rows can show visible feedback in the UI.
enum ProbeState: Equatable {
    case idle
    case connecting
    case discovered      // services found, name updated (or attempted)
    case failed(String)
}

/// An in-memory representation of a discovered BLE peripheral.
/// Lives only for the duration of a scanning session — persisted state
/// belongs in `StoredDevice`.
struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID                 // CBPeripheral.identifier
    var name: String
    var rssi: Int                // latest raw RSSI sample, dBm
    /// Exponentially-smoothed RSSI. Driven by an EMA in BluetoothManager so
    /// the distance readout and proximity band don't twitch between every
    /// advertisement packet. All UI computations should prefer this over
    /// `rssi`.
    var smoothedRSSI: Double
    var lastSeen: Date
    var manufacturerData: Data?
    var advertisedServiceUUIDs: [CBUUID]
    var peripheral: CBPeripheral?
    var probeState: ProbeState = .idle
    var probeDetail: String? = nil   // human-readable dump of services, set on success

    /// Per-device calibrated transmit-power reference (RSSI at 1 meter), in dBm.
    /// Persisted across launches in `UserDefaults` by BluetoothManager. When
    /// present, the distance estimate uses this instead of the generic -59 dBm
    /// default, cancelling out the single biggest source of error.
    var calibratedTxPowerAt1m: Double? = nil

    /// Normalized proximity in [0, 1]. Uses the smoothed RSSI so the radar
    /// and proximity band update slowly. Maps a typical BLE range of roughly
    /// -100 dBm (far) .. -35 dBm (touching) to 0..1. Clamped.
    var proximity: Double {
        let minRSSI = -100.0
        let maxRSSI = -35.0
        let clamped = max(minRSSI, min(maxRSSI, smoothedRSSI))
        return (clamped - minRSSI) / (maxRSSI - minRSSI)
    }

    // MARK: - Distance estimate

    /// Rough distance in meters using the log-distance path-loss model:
    ///
    ///     d = 10 ^ ((txPower - rssi) / (10 * n))
    ///
    /// `txPower` is the expected RSSI at 1 meter and `n` is the path-loss
    /// exponent (~2.5 indoors). If the user has calibrated this specific
    /// device we use their measured reference; otherwise we fall back to
    /// the BLE-spec default of -59 dBm. Still noisy, but calibration cancels
    /// out the tx-power variance between different Soundcore models, which
    /// is usually the biggest source of error.
    var approximateMeters: Double {
        let txPower = calibratedTxPowerAt1m ?? -59.0
        let n = 2.5
        guard smoothedRSSI < 0 else { return 0 }
        return pow(10.0, (txPower - smoothedRSSI) / (10.0 * n))
    }

    /// True when the user has taught the app this specific device's
    /// reference power by standing at a known distance and tapping Calibrate.
    var isCalibrated: Bool { calibratedTxPowerAt1m != nil }

    var approximateFeet: Double {
        approximateMeters * 3.28084
    }

    /// Human-readable distance in feet. Rounded to the nearest 2 ft in the
    /// middle range to hide EMA jitter, with a "< 2 ft" floor and a "30+ ft"
    /// ceiling past the point where BLE estimates stop being meaningful.
    var distanceLabel: String {
        let ft = approximateFeet
        if ft < 2 { return "< 2 ft" }
        if ft >= 30 { return "30+ ft" }
        let rounded = max(2, (Int(ft.rounded()) / 2) * 2)
        return "\(rounded) ft"
    }

    var proximityBand: ProximityBand {
        switch proximity {
        case 0.66...: return .hot
        case 0.33..<0.66: return .warm
        default: return .cold
        }
    }

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum ProximityBand {
    case cold, warm, hot

    var label: String {
        switch self {
        case .cold: return "Far"
        case .warm: return "Getting warmer"
        case .hot:  return "Very close"
        }
    }
}

/// Persisted record of a Soundcore device the user has seen before.
/// Includes the last GPS fix captured while the device was in range.
@Model
final class StoredDevice {
    @Attribute(.unique) var id: UUID
    var name: String
    var firstSeen: Date
    var lastSeen: Date
    var lastRSSI: Int
    var lastLatitude: Double?
    var lastLongitude: Double?
    var lastLocationTimestamp: Date?
    var isFavorite: Bool

    init(
        id: UUID,
        name: String,
        firstSeen: Date = .now,
        lastSeen: Date = .now,
        lastRSSI: Int = -100,
        lastLatitude: Double? = nil,
        lastLongitude: Double? = nil,
        lastLocationTimestamp: Date? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.lastRSSI = lastRSSI
        self.lastLatitude = lastLatitude
        self.lastLongitude = lastLongitude
        self.lastLocationTimestamp = lastLocationTimestamp
        self.isFavorite = isFavorite
    }

    var lastCoordinate: CLLocationCoordinate2D? {
        guard let lat = lastLatitude, let lon = lastLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
