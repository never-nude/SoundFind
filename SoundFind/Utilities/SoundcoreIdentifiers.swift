import Foundation
import CoreBluetooth

/// Known identifiers used to recognize Soundcore / Anker BLE devices.
///
/// Soundcore is Anker's audio brand. Anker's BLE company identifier (as
/// registered with the Bluetooth SIG) is 0x049A. Devices typically advertise
/// either a custom GATT service or manufacturer data prefixed with that ID.
/// Name prefixes are the most reliable filter in practice because Anker
/// advertises the friendly product name in the scan response.
enum SoundcoreIdentifiers {

    /// Anker Innovations Limited company ID (Bluetooth SIG).
    static let ankerCompanyID: UInt16 = 0x049A

    /// Known Soundcore / Anker GATT service UUIDs observed in the wild.
    /// These are used for scanning filters and for opportunistic "play sound"
    /// attempts. Not every model exposes every service.
    static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "0000FD82-0000-1000-8000-00805F9B34FB"), // Soundcore proprietary
        CBUUID(string: "0000FE2C-0000-1000-8000-00805F9B34FB"), // Google Fast Pair (Anker uses this)
        CBUUID(string: "0000110B-0000-1000-8000-00805F9B34FB")  // A2DP sink (classic, sometimes advertised)
    ]

    /// Friendly-name prefixes that indicate a Soundcore product.
    static let namePrefixes: [String] = [
        "Soundcore",
        "Anker Soundcore",
        "Liberty",
        "Life",
        "Space",
        "Frames",
        "Motion",
        "AeroFit",
        "Sport"
    ]

    /// Well-known characteristic UUIDs that some Soundcore firmware exposes
    /// for a "find my earbuds" tone. These are best-effort; writing to them
    /// on an unsupported model will simply fail silently.
    static let findMyCharacteristicUUIDs: [CBUUID] = [
        CBUUID(string: "0000FD83-0000-1000-8000-00805F9B34FB"),
        CBUUID(string: "0000FE2D-0000-1000-8000-00805F9B34FB")
    ]

    /// Returns true if an advertised peripheral looks like a Soundcore device.
    static func isSoundcore(name: String?, manufacturerData: Data?, serviceUUIDs: [CBUUID]?) -> Bool {
        if let name {
            for prefix in namePrefixes where name.localizedCaseInsensitiveContains(prefix) {
                return true
            }
        }
        if let manufacturerData, manufacturerData.count >= 2 {
            let companyID = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
            if companyID == ankerCompanyID { return true }
        }
        if let serviceUUIDs {
            let known = Set(knownServiceUUIDs)
            if !serviceUUIDs.allSatisfy({ !known.contains($0) }) { return true }
        }
        return false
    }
}
