# SoundFind — open work

Three problems the user has reported with the current build, in priority
order. Read `CLAUDE.md` first for architecture, build commands, and the
"do not regress" list.

All testing happens on a real iPhone — BLE is dead on the Simulator.
Target device: iPhone 15, UDID `4F2F6694-5155-533E-BFDC-51C7178F535A`.

Target BLE peripherals for manual testing:

- **Soundcore Space One** (over-ear). Advertises with a friendly name
  ("Soundcore Space One LE") when in pairing mode, but goes nameless
  once classic-BT-paired for audio.
- **Soundcore B20i** (open-ear earbuds). Same story.

The user wears / actively uses both, which means they are typically
connected over classic Bluetooth (A2DP) to the iPhone during testing.
Expect iOS privacy scrubbing of names and periodic RPA rotation.

---

## Problem 1 — Confirmed Soundcores disappear after RPA rotation

**Symptom.** The user taps Identify on an `Unnamed (xxxxxxxx)` row in
debug mode, the probe succeeds, the row briefly updates with the real
name ("soundcore Space One LE"). A few minutes later the same physical
device shows up as a brand-new `Unnamed (yyyyyyyy)` row and has to be
re-identified.

**Root cause.** iOS rotates Resolvable Private Addresses (RPAs) every
~15 minutes for privacy. Each rotation changes `CBPeripheral.identifier`,
so CoreBluetooth hands us what looks like a fresh peripheral. Our
`discovered: [UUID: DiscoveredDevice]` dictionary is keyed on that
rotating UUID, and the old row ages out of the 15-second stale window
after a few seconds of no advertisements on the old address.

**Proposed fix — fingerprint-based continuity.**

- Add a new type in `Models/SoundcoreDevice.swift`:

  ```swift
  struct SoundcoreFingerprint: Codable, Hashable {
      let manufacturerDataHex: String      // full hex, not just company ID
      let serviceUUIDs: [String]           // sorted CBUUID strings
      let friendlyName: String             // what we saw at confirm time
  }
  ```

- Maintain `confirmedFingerprints: Set<SoundcoreFingerprint>` in
  `BluetoothManager`, persisted as a JSON array in `UserDefaults` under
  key `"SoundFind.confirmedFingerprints.v1"`. Load on init.

- On every advertisement in `didDiscover`, compute a `SoundcoreFingerprint`
  from the ad data (ignore the UUID — that's the whole point). Compare it
  against `confirmedFingerprints`. If it matches, short-circuit the
  SoundcoreIdentifiers filter and add the row to `discovered` with the
  remembered friendly name. This works across RPA rotations because
  the ad-level fingerprint is stable even when the UUID isn't.

- Add a swipe action to debug-mode rows labelled **"Confirm as Soundcore"**.
  On tap, compute the fingerprint from the current entry, add it to the
  set, persist, and immediately promote the row into the normal filter.

- Also auto-confirm when an `identify()` probe returns a non-nil
  `peripheral.name` containing any `SoundcoreIdentifiers.namePrefixes`
  substring. This way, manual Identify → auto-remember for next time.

- Extend the stale cutoff in `tickRefresh()` to 60 seconds for rows whose
  peripheral matches a confirmed fingerprint, so they don't vanish during
  normal coverage gaps.

Success criterion: the user taps Confirm on a Space One row once, closes
the app, walks around, launches the app 20 minutes later (after the RPA
has definitely rotated), and sees the Space One appear in normal-mode
list within 5 seconds of scanning.

---

## Problem 2 — Confirmed Soundcores don't appear in normal (non-debug) mode

**Symptom.** Even when the user has just seen the Space Ones in debug
mode and confirmed their identity, flipping debug off makes them vanish.
The name prefix filter in `SoundcoreIdentifiers.isSoundcore()` never
matches because:

- Advertised name is empty (iOS scrubs for classic-BT-paired devices)
- Manufacturer data prefix is `0xB224` (NOT Anker's `0x049A`)
- No known Soundcore service UUIDs in the ad

Problem 2 is effectively the same root cause as Problem 1 from a
different angle. The fingerprint approach above solves it too: any
peripheral whose ad data matches a confirmed fingerprint passes the
non-debug filter automatically.

If Problem 1 is solved with Approach A above, Problem 2 needs no
additional code. If that's not the path chosen, a minimum-viable fallback
is a session whitelist of `[UUID]` in UserDefaults, but this decays every
RPA rotation — only do it as a stopgap.

---

## Problem 3 — Distance estimates are off by a factor of 5+

**Symptom.** User walks to a known 12 ft distance. Readout says "2 ft".
Even after single-point calibration, estimates stay compressed. This is
not a smoothing bug — the model is wrong.

**Root cause.** `approximateMeters` on `DiscoveredDevice` uses the
log-distance path-loss model:

```
distance_m = 10 ** ((txPower_1m - smoothedRSSI) / (10 * n))
```

with `n` hardcoded to 2.5 and `txPower_1m` either calibrated (single
point, stored on `DiscoveredDevice.calibratedTxPowerAt1m`) or defaulted
to -59 dBm. There are **two unknowns** (`txPower_1m` and `n`) but the
current calibration only fixes one of them. If the true `n` in the
user's environment is 3.5-4 (walls, furniture, body blocking) and we're
using 2.5, distances stay systematically short by a large factor at any
range that wasn't the calibration point.

**Proposed fix — two-point calibration.**

Change the calibration math and UI so the user provides TWO samples at
different known distances, and we solve analytically for both unknowns:

```
Let r1 = smoothedRSSI at distance d1 (meters)
Let r2 = smoothedRSSI at distance d2 (meters)

n          = (r1 - r2) / (10 * (log10(d2) - log10(d1)))
txPower_1m = r1 + 10 * n * log10(d1)
```

- Add `calibratedPathLossExponent: Double?` to `DiscoveredDevice`.
- Update `approximateMeters` to read both constants, falling back to
  `-59.0` and `2.5` when absent.
- Clamp `n` to `[1.8, 5.0]` on save — out-of-range values indicate a
  bad sample (wrong distance, multipath outlier). If clamped, surface a
  small warning in the UI so the user knows to retry.
- Persist both values alongside the existing UserDefaults entry under
  `"SoundFind.calibrations.v2"`. Keep the v1 key readable for backward
  compatibility, migrate on first load.

**UI changes in `Views/DeviceDetailView.swift`:**

Replace the current single-stepper calibration card with a two-step
card:

1. "Near distance" stepper, default 3, range 1..10 ft.
2. "Sample Near" button. Captures current `smoothedRSSI` into
   `@State private var nearSample: (rssi: Double, feet: Double)?`. Shows
   a checkmark once captured.
3. "Far distance" stepper, default 10, range 5..20 ft.
4. "Sample Far" button. Same pattern into `farSample`. Disable until
   Near has been captured. Enforce `farFeet > nearFeet`.
5. "Save Calibration" button. Enabled only when both samples are set.
   On tap, solve the system, clamp `n`, persist, flash green "Calibrated ✓"
   for 2 s.
6. "Reset" button clears both samples and the persisted calibration for
   this device.

Also surface both constants in the metadata section so the user can
sanity-check what the model is doing:

```swift
if let tx = stored.calibratedTxPowerAt1m {
    row("Tx power (1 m)", String(format: "%.1f dBm", tx))
}
if let n = stored.calibratedPathLossExponent {
    row("Path loss n",    String(format: "%.2f", n))
}
```

**`BluetoothManager` API change:**

Replace the current `calibrate(deviceID:atFeet:)` with:

```swift
func calibrate(
    deviceID: UUID,
    near: (rssi: Double, feet: Double),
    far:  (rssi: Double, feet: Double)
)
```

Keep `clearCalibration(deviceID:)` as-is — it should now clear both
values.

**Success criterion.**

After calibrating at 3 ft and 10 ft, the user walks to a measured 12 ft
and the readout shows between 10 and 14 ft. Walking to 5 ft shows 4-6 ft.
Touching the device shows "< 2 ft". This is the realistic ceiling for
non-UWB BLE and should feel accurate.

---

## Priority / sequencing

1. **Problem 3 first** (two-point calibration) — self-contained, biggest
   UX win, and independent of the fingerprint work.
2. **Problem 1** (fingerprint continuity) — solves Problem 2 for free,
   but is a larger change touching three files.
3. **Problem 2** only needs dedicated code if Problem 1 isn't implemented.

Stop after each problem is complete, run a device build, and verify on
the iPhone before moving to the next.

## Test procedure per problem

For each problem, the smoke test is:

```bash
cd ~/Desktop/SoundFind
xcodegen generate          # only if project.yml changed
xcodebuild \
  -project SoundFind.xcodeproj \
  -scheme SoundFind \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/soundfind-build \
  -allowProvisioningUpdates \
  build 2>&1 | tail -10

DEVICE_ID=4F2F6694-5155-533E-BFDC-51C7178F535A
APP=/tmp/soundfind-build/Build/Products/Debug-iphoneos/SoundFind.app
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
xcrun devicectl device process launch --device "$DEVICE_ID" \
  --terminate-existing com.kushman.SoundFind
```

Then hand the phone back to the user with a short note describing what
to do to verify.

## Things to explicitly NOT do

- Do not modify `project.yml` signing keys, bundle ID, or team.
- Do not attempt GUI automation of Xcode.
- Do not refactor unrelated code, rename files, or add dependencies.
- Do not re-enable GATT `0x2A00` reads.
- Do not regress any item in the "Do not regress" list of `CLAUDE.md`.
