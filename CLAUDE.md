# SoundFind — agent context

This file is for any agent (Claude Code, Cowork, Codex, etc.) picking up
work on SoundFind. Read this before touching the code.

SoundFind is a Find My–style iOS app that locates nearby Soundcore (Anker)
Bluetooth headphones by BLE advertisement. It is driven entirely from the
terminal — **do not open Xcode.app** unless the user explicitly asks.

## Tech stack

- Swift 5.9+, SwiftUI, targeting iOS 17+
- SwiftData for persistence (`StoredDevice @Model`), NOT Core Data
- CoreBluetooth for BLE scanning and GATT writes
- CoreLocation for last-known GPS
- MapKit for the map view
- CoreHaptics for the continuous tracking pulse

## Architecture (MVVM)

```
SoundFind/
├── SoundFindApp.swift           @main. Declares the shared ModelContainer
│                                 and injects BluetoothManager + LocationManager
│                                 as environment objects.
├── Models/
│   └── SoundcoreDevice.swift    DiscoveredDevice (transient struct) and
│                                 StoredDevice (@Model). DiscoveredDevice owns
│                                 smoothedRSSI, calibratedTxPowerAt1m,
│                                 approximateMeters / approximateFeet /
│                                 distanceLabel, proximity band math.
├── Managers/
│   ├── BluetoothManager.swift   @MainActor ObservableObject. CBCentralManager
│   │                             + CBPeripheralDelegate. Scans continuously,
│   │                             applies the Soundcore filter (or bypasses it
│   │                             in debug mode), smooths RSSI via EMA,
│   │                             maintains a `stableOrder: [UUID]` for the
│   │                             UI with 3 dB hysteresis, implements identify()
│   │                             (GATT probe) and playSound() (best-effort
│   │                             find-me write), plus per-device calibration
│   │                             persistence via UserDefaults.
│   └── LocationManager.swift    @MainActor ObservableObject wrapper around
│                                 CLLocationManager, publishes lastLocation.
├── ViewModels/
│   └── DeviceViewModel.swift    iOS 17 `@Observable` class. Bridges
│                                 BluetoothManager → SwiftData. Merges every
│                                 advertisement into StoredDevice, producing
│                                 a list of Row structs for the UI. Created
│                                 lazily inside ContentView.task { } from the
│                                 injected modelContext. IMPORTANT: do NOT
│                                 convert this back to ObservableObject +
│                                 @StateObject and do NOT spin up a placeholder
│                                 ModelContainer in ContentView.init() — that
│                                 caused a Swift runtime trap inside SwiftData's
│                                 metadata resolver. See "Do not regress".
├── Views/
│   ├── ContentView.swift        Root. Map + bottom sheet + header capsule
│   │                             with scan toggle + debug eye icon + error
│   │                             banner. Presents DeviceListView and the
│   │                             per-device DeviceDetailView sheet.
│   ├── MapView.swift            MapKit w/ user location + markers per device.
│   ├── DeviceListView.swift     The bottom sheet. Shows "In Range" / "Seen
│   │                             Before" sections. In debug mode the In Range
│   │                             section becomes "All BLE Devices (tap to
│   │                             identify)" and tapping fires a GATT probe
│   │                             instead of opening the detail sheet.
│   ├── RadarView.swift          The Find My–style pulsing orb. Driven by
│   │                             proximity [0, 1]. Shows a qualitative label
│   │                             ("Very Close" / "Near" / "Warm" / "Far" /
│   │                             "Very Far") and a big distance number only
│   │                             when the device is calibrated.
│   └── DeviceDetailView.swift   The detail sheet. Shows RadarView (or map
│                                 fallback when out of range), a Calibrate
│                                 card with a feet stepper, a Play Sound
│                                 button, and a metadata section. Also sets
│                                 bluetooth.focusedDeviceID on appear/disappear.
├── Utilities/
│   ├── SoundcoreIdentifiers.swift  Name prefixes, Anker company ID (0x049A),
│   │                                known service UUIDs, and a best-effort
│   │                                list of Find-Me characteristic UUIDs.
│   │                                The `isSoundcore(...)` function is the
│   │                                non-debug filter.
│   └── HapticManager.swift      CoreHaptics with UIImpactFeedbackGenerator
│                                 fallback. `pulse(forProximity:)` throttles
│                                 itself, period scales from 900 ms (far)
│                                 down to 120 ms (touching). RadarView drives
│                                 it in a continuous `.task { }` loop.
└── Resources/
    └── Info.plist               Usage descriptions + UIBackgroundModes for
                                  bluetooth-central and location. DO NOT let
                                  xcodegen regenerate this — see gotchas.
```

## Signing, bundle ID, and device

- **Team ID**: `QHUS8AZVD4` (Michael Kushman, personal team). Read from the
  cert's `OU`, not the `CN` — the cert's CN contains a user-ID parenthetical
  (`598Z6QP7FL`) that is NOT the team ID. A previous agent burned half an
  hour on that.
- **Bundle ID**: `com.kushman.SoundFind`
- **Xcode account**: michael.kushman@gmail.com is registered in
  Xcode → Settings → Accounts. `-allowProvisioningUpdates` works from CLI.
- **Target device**: iPhone 15, UDID
  `4F2F6694-5155-533E-BFDC-51C7178F535A`, paired and available.

## Build / install / launch from terminal

```bash
# Regenerate the Xcode project after any project.yml change
cd ~/Desktop/SoundFind
xcodegen generate

# Build for device. Derived data lives at /tmp/ to sidestep the iCloud
# fileprovider xattr issue (see gotchas).
xcodebuild \
  -project SoundFind.xcodeproj \
  -scheme SoundFind \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/soundfind-build \
  -allowProvisioningUpdates \
  build

# Install and (re)launch. The iPhone must be unlocked.
DEVICE_ID=4F2F6694-5155-533E-BFDC-51C7178F535A
APP=/tmp/soundfind-build/Build/Products/Debug-iphoneos/SoundFind.app
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
xcrun devicectl device process launch --device "$DEVICE_ID" \
  --terminate-existing com.kushman.SoundFind
```

Building for the simulator works too (`-destination 'platform=iOS Simulator,
name=iPhone 17 Pro'`), but BLE does nothing in the sim — no radio. Only
the UI, persistence, and permission prompts are testable there.

## Gotchas (read before editing)

### iCloud Desktop fileprovider breaks codesign
`~/Desktop` is iCloud-synced, and the fileprovider stamps every newly-created
directory with `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P`
xattrs. `codesign` refuses to sign bundles with those xattrs. **Always build
to `-derivedDataPath /tmp/soundfind-build`** (or anywhere outside
`~/Desktop` and `~/Documents`). If you hit
`resource fork, Finder information, or similar detritus not allowed`,
this is why.

### xcodegen wants to own Info.plist
If `project.yml` has a `targets.SoundFind.info:` block, xcodegen will
regenerate `Info.plist` on every run, wiping the BLE / Location usage
descriptions and background modes. **Do not re-add that key.** Keep only
`settings.INFOPLIST_FILE: SoundFind/Resources/Info.plist` and list
`SoundFind/Resources/Info.plist` under `sources.excludes` so xcodegen
doesn't also copy it as a resource.

### SourceKit loose-file false positives
Editing Swift files outside a real Xcode project context produces noisy
"Cannot find type in scope" and "No such module" diagnostics that you can
safely ignore. Only trust errors from actual `xcodebuild` runs. Types like
`BluetoothManager`, `StoredDevice`, `DiscoveredDevice`, and
`SoundcoreIdentifiers` all live in sibling files in the same target and
will resolve correctly at build time.

### CBPeripheralDelegate callbacks are nonisolated
All `CBCentralManagerDelegate` and `CBPeripheralDelegate` methods on
`BluetoothManager` are declared `nonisolated` because the protocol requires
it. Inside them, hop to main-actor state via `Task { @MainActor in ... }`.
Do not read or write `@Published` state from the nonisolated portion.

### iOS hides the GATT Device Name characteristic
`0x1800` (Generic Access) and specifically `0x2A00` (Device Name) are
filtered out by iOS for third-party apps. Any code that reads `0x2A00` is
dead weight and should be replaced with `discoverServices(nil)` +
`peripheral.name` after connect, which may pull a cached classic-BT name.

### Per-SDK signing
Simulator builds skip signing; device builds require it. This is enforced
by per-SDK keys in `project.yml`:

```yaml
"CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]": "NO"
"CODE_SIGNING_ALLOWED[sdk=iphoneos*]": "YES"
"CODE_SIGNING_REQUIRED[sdk=iphoneos*]": "YES"
```

Don't remove these. Changing signing style breaks one or the other build
path.

## Do not regress

A previous agent made each of these mistakes. Do not repeat them.

1. **Do not reintroduce the placeholder ModelContainer.** `DeviceViewModel`
   must be `@Observable`, created lazily inside `ContentView.task` from the
   injected `@Environment(\.modelContext)`. A second ModelContainer for
   `StoredDevice` causes a Swift runtime trap (`EXC_BREAKPOINT`) inside
   SwiftData's metadata resolver on first Combine emission.
2. **Do not use team ID `598Z6QP7FL`.** That's a user ID in the cert's
   CN, not the team ID. The real team ID is `QHUS8AZVD4` (the cert's OU).
3. **Do not hand-write a `project.pbxproj`.** Let xcodegen do it.
4. **Do not read GATT `0x2A00`.** iOS blocks it. Use `peripheral.name`
   post-connect or infer identity from advertisement fingerprints.
5. **Do not build into `~/Desktop/SoundFind/build/`.** iCloud xattrs break
   codesign. Use `/tmp/soundfind-build/` or any non-iCloud path.
6. **Do not trust SourceKit diagnostics.** Only believe `xcodebuild` errors.

## Open work

See `TASK.md` for the prioritized list of problems to solve and proposed
approaches.
