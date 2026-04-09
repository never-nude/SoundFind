# SoundFind

An iOS app (Swift / SwiftUI) that locates nearby Soundcore (Anker) Bluetooth
headphones and headsets. Inspired by Apple's **Find My** interface.

## Features

- **BLE scanner** — `CoreBluetooth` scan filtered to Soundcore devices by
  name prefix, Anker manufacturer ID (`0x049A`), and known service UUIDs.
- **Signal-strength radar** — live RSSI rendered as a pulsing cold/warm/hot
  radar overlay that speeds up and reddens as you walk closer.
- **Last known location** — every advertisement captures the device's GPS
  fix via `CoreLocation` and stores it in SwiftData for later recall on a
  `MapKit` map.
- **Play sound** — best-effort GATT write to a Soundcore "find my earbuds"
  characteristic. Fails silently on models that don't expose one.
- **Device list** — persisted list of every device the app has ever seen,
  with relative "last seen" timestamps, favorites, and swipe-to-forget.
- **Haptics** — `CoreHaptics` pulses that quicken and intensify as you
  get closer to the target device.
- **Dark mode** — inherits the system appearance via `.preferredColorScheme(nil)`.

## Architecture (MVVM)

```
SoundFind/
├── SoundFindApp.swift            # @main, ModelContainer, environment objects
├── Models/
│   └── SoundcoreDevice.swift     # DiscoveredDevice (transient), StoredDevice (@Model)
├── Managers/
│   ├── BluetoothManager.swift    # CBCentralManager + CBPeripheralDelegate, @MainActor
│   └── LocationManager.swift     # CLLocationManagerDelegate wrapper
├── ViewModels/
│   └── DeviceViewModel.swift     # merges live scans with SwiftData persistence
├── Views/
│   ├── ContentView.swift         # Map + bottom sheet composition
│   ├── MapView.swift             # MapKit w/ annotations + user location
│   ├── DeviceListView.swift      # "In Range" + "Seen Before" sections
│   ├── RadarView.swift           # pulsing proximity radar
│   └── DeviceDetailView.swift    # radar, map fallback, Play Sound button
├── Utilities/
│   ├── SoundcoreIdentifiers.swift  # UUIDs, company IDs, name prefixes
│   └── HapticManager.swift         # CoreHaptics w/ UIImpact fallback
└── Resources/
    └── Info.plist                # required usage strings + background modes
```

## Setup

1. Create a new Xcode iOS App project targeting **iOS 17.0+**, Swift 5.9+,
   interface **SwiftUI**, storage **SwiftData**. Name it `SoundFind`.
2. Delete Xcode's stub `ContentView.swift` and `SoundFindApp.swift`.
3. Drag every file from this folder (including `Info.plist`) into the
   Xcode project navigator and copy them into the target.
4. In Signing & Capabilities, add:
   - **Background Modes** → *Uses Bluetooth LE accessories* and
     *Location updates*.
5. Build to a real device. BLE does not work in the simulator.

> **Note on loose-file diagnostics:** because these files live outside an
> Xcode project on disk, SourceKit may raise "Cannot find type in scope",
> "No such module 'UIKit'", and SwiftData/Foundation macro errors when
> scanning them standalone. They all disappear once the files are part
> of an Xcode iOS 17 target.

## Permissions

`Info.plist` declares:

| Key | Purpose |
| --- | --- |
| `NSBluetoothAlwaysUsageDescription` | Needed to scan for Soundcore devices. |
| `NSBluetoothPeripheralUsageDescription` | Needed to connect for the Play Sound write. |
| `NSLocationWhenInUseUsageDescription` | Needed to record last-seen GPS fix. |
| `UIBackgroundModes` | `bluetooth-central`, `location` for brief background scans. |

## Caveats

- Anker/Soundcore's BLE protocol is proprietary and varies by model. The
  "Play Sound" feature uses reasonable guesses for the find-my characteristic
  UUID and ring byte (`0x01`); if a device doesn't recognize the write,
  nothing happens — no harm done.
- RSSI → distance is inherently noisy. Treat the radar as "warmer/colder",
  not as a metric distance.
- Background scanning on iOS is throttled; when the screen locks, expect
  discovery latency to grow.
