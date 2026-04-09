import Foundation
import CoreBluetooth
import Combine

/// Scans for Soundcore BLE devices, keeps a live map of discoveries,
/// and attempts best-effort "play sound" writes when asked.
///
/// All published state is updated on the main queue so SwiftUI views
/// can observe it directly.
@MainActor
final class BluetoothManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var discovered: [UUID: DiscoveredDevice] = [:]
    @Published private(set) var lastError: String?

    /// Visible, stable display order for the discovered devices. Refreshed
    /// on a 2-second cadence with RSSI hysteresis so rows don't hop around
    /// while the user tries to tap them.
    @Published private(set) var stableOrder: [UUID] = []

    /// Exponential smoothing factor for RSSI. Lower = slower to react but
    /// much more stable. 0.15 gives a time constant of roughly 1 second
    /// at typical BLE advertisement rates.
    private let rssiSmoothingAlpha: Double = 0.15

    /// Path-loss exponent used for distance calibration math.
    /// 2.0 = free space, 2.5 = typical indoor, 3.0+ = heavily obstructed.
    private let pathLossExponent: Double = 2.5

    /// In-memory cache of per-device calibrations (RSSI-at-1-meter, dBm),
    /// keyed by peripheral UUID string. Loaded from UserDefaults at init
    /// and written back on every calibrate() call.
    private var calibrationCache: [String: Double] = [:]
    private static let calibrationDefaultsKey = "SoundFind.calibrations.v1"

    /// Debug toggle: when true, every named BLE peripheral is surfaced
    /// regardless of the Soundcore filter. Use to find out what your
    /// headphones actually advertise as.
    @Published var debugShowAll: Bool = false

    /// The device the user is currently focused on — usually because they
    /// tapped its row and opened the detail/radar sheet. Other views (e.g.
    /// the map) can highlight or zoom to this peripheral, and the radar
    /// drives continuous haptics off it.
    @Published var focusedDeviceID: UUID?

    /// Legacy alias, kept so older call sites don't break.
    @Published var trackedDeviceID: UUID?

    // MARK: - Private

    private var centralManager: CBCentralManager!
    private var staleTimer: Timer?

    /// Peripherals we've started a connect attempt on, keyed by ID,
    /// so we can complete the play-sound handshake in the delegate callbacks.
    private var connectingPeripherals: [UUID: CBPeripheral] = [:]

    /// What the user asked us to do once the connection completes.
    enum PendingAction {
        case playSound
        case identify
    }
    private var pendingActions: [UUID: PendingAction] = [:]

    /// For identify: how many services we're still waiting on characteristic
    /// discovery for. When this hits 0 we call `finishProbe`.
    private var pendingServiceCount: [UUID: Int] = [:]

    /// Scratch accumulator of services whose characteristics have been discovered
    /// during an identify probe.
    private var probeServices: [UUID: [CBService]] = [:]

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
        loadCalibrations()
        startStaleSweep()
    }

    // MARK: - Calibration persistence

    private func loadCalibrations() {
        let defaults = UserDefaults.standard
        if let raw = defaults.dictionary(forKey: Self.calibrationDefaultsKey) as? [String: Double] {
            calibrationCache = raw
        }
    }

    private func saveCalibrations() {
        UserDefaults.standard.set(calibrationCache, forKey: Self.calibrationDefaultsKey)
    }

    /// Teach SoundFind how this specific device behaves. The user holds the
    /// phone `feet` feet from the peripheral and taps Calibrate. We back-
    /// calculate the theoretical RSSI-at-1-meter reference using the
    /// log-distance path-loss model and store it, both in-memory (so the
    /// current live row immediately updates) and in UserDefaults (so the
    /// calibration survives launches).
    ///
    ///     txPower_1m = currentRSSI + 10 * n * log10(distanceMeters)
    ///
    func calibrate(deviceID: UUID, atFeet feet: Double) {
        guard var entry = discovered[deviceID] else {
            lastError = "Device is no longer in range — can't calibrate."
            return
        }
        let meters = max(0.25, feet * 0.3048)
        let refAt1m = entry.smoothedRSSI + 10.0 * pathLossExponent * log10(meters)

        entry.calibratedTxPowerAt1m = refAt1m
        discovered[deviceID] = entry

        calibrationCache[deviceID.uuidString] = refAt1m
        saveCalibrations()
    }

    /// Forget a previous calibration for a device. The row reverts to the
    /// generic -59 dBm default on the next distance calculation.
    func clearCalibration(deviceID: UUID) {
        calibrationCache.removeValue(forKey: deviceID.uuidString)
        saveCalibrations()
        if var entry = discovered[deviceID] {
            entry.calibratedTxPowerAt1m = nil
            discovered[deviceID] = entry
        }
    }

    deinit {
        staleTimer?.invalidate()
    }

    // MARK: - Scanning

    func startScanning() {
        guard state == .poweredOn else {
            lastError = "Bluetooth is not powered on."
            return
        }
        guard !isScanning else { return }
        // Scan for everything; we filter by name/manufacturer because not all
        // Soundcore firmware advertises its primary service in the main packet.
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        isScanning = true
        lastError = nil
    }

    func stopScanning() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
    }

    func toggleScanning() {
        isScanning ? stopScanning() : startScanning()
    }

    /// Toggles the unfiltered debug mode and clears the current discovery list
    /// so stale entries from the other mode don't linger.
    func toggleDebugMode() {
        debugShowAll.toggle()
        discovered.removeAll()
    }

    /// Drops stale devices AND recomputes `stableOrder`. Runs every 2 seconds.
    /// The re-sort is intentionally slow so rows don't jump around while the
    /// user is trying to tap one.
    private func startStaleSweep() {
        staleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickRefresh()
            }
        }
    }

    /// One tick of the stable-order refresh. Called from a 2-second timer.
    @MainActor
    private func tickRefresh() {
        // 1. Evict anything we haven't seen in a while.
        let cutoff = Date().addingTimeInterval(-15)
        discovered = discovered.filter { $0.value.lastSeen > cutoff }

        // 2. Compute the new order. We bucket smoothed RSSI into 3 dB slots
        //    so small fluctuations don't cause adjacent swaps (~roughly 1.5 ft
        //    of hysteresis), and break ties by previous position so things
        //    stay visually anchored.
        let previousIndex: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: stableOrder.enumerated().map { ($1, $0) })

        func bucket(_ rssi: Double) -> Int {
            // Higher RSSI (closer) → higher bucket number.
            Int((rssi / 3.0).rounded())
        }

        let newOrder = discovered.keys.sorted { a, b in
            let ra = discovered[a]?.smoothedRSSI ?? -100
            let rb = discovered[b]?.smoothedRSSI ?? -100
            let ba = bucket(ra)
            let bb = bucket(rb)
            if ba != bb { return ba > bb }
            // Same bucket: keep whatever order they had before. Unknown IDs
            // (new arrivals) go to the back of their bucket.
            let ia = previousIndex[a] ?? Int.max
            let ib = previousIndex[b] ?? Int.max
            return ia < ib
        }

        stableOrder = newOrder
    }

    // MARK: - Play Sound (best-effort)

    /// Attempts to connect to the peripheral and write a "ring" byte to any
    /// characteristic that looks like a Soundcore find-my command channel.
    /// Fails silently if the device doesn't expose one.
    func playSound(on deviceID: UUID) {
        guard let discovered = discovered[deviceID],
              let peripheral = discovered.peripheral else {
            lastError = "Device is no longer in range."
            return
        }
        pendingActions[deviceID] = .playSound
        connectingPeripherals[deviceID] = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    // MARK: - Identify (debug: read GATT Device Name)

    /// Connects briefly and enumerates all services on the peripheral.
    /// iOS will also opportunistically populate `peripheral.name` from its
    /// classic-Bluetooth cache once the connection is established, so by the
    /// time `didConnect` fires we often already have a real name even for
    /// peripherals that advertised nameless.
    ///
    /// Updates the row's `probeState` visibly as it progresses.
    func identify(_ deviceID: UUID) {
        guard var entry = discovered[deviceID],
              let peripheral = entry.peripheral else {
            lastError = "Device is no longer in range."
            return
        }
        entry.probeState = .connecting
        discovered[deviceID] = entry

        pendingActions[deviceID] = .identify
        connectingPeripherals[deviceID] = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: false,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: false
        ])

        // If nothing happens after 8 seconds, mark it failed so the user sees feedback.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if var e = self.discovered[deviceID], case .connecting = e.probeState {
                e.probeState = .failed("Timed out")
                self.discovered[deviceID] = e
                self.pendingActions.removeValue(forKey: deviceID)
                self.connectingPeripherals.removeValue(forKey: deviceID)
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    /// Pull the name from peripheral.name (which iOS may populate from the
    /// classic-BT cache post-connect) into our discovered row.
    @MainActor
    fileprivate func refreshNameFromPeripheral(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard var entry = discovered[id] else { return }
        if let n = peripheral.name, !n.isEmpty, n != entry.name {
            entry.name = n
        }
        discovered[id] = entry
    }

    /// Write a human-readable dump of what the peripheral exposed, so the
    /// user can see signal-of-life in the UI.
    @MainActor
    fileprivate func finishProbe(_ peripheral: CBPeripheral, services: [CBService]) {
        let id = peripheral.identifier
        guard var entry = discovered[id] else { return }

        var lines: [String] = []
        if let n = peripheral.name, !n.isEmpty {
            lines.append("name: \(n)")
        }
        for s in services {
            let u = s.uuid.uuidString
            let chars = s.characteristics?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? ""
            lines.append("svc \(u): [\(chars)]")
        }
        entry.probeState = .discovered
        entry.probeDetail = lines.joined(separator: "\n")
        discovered[id] = entry

        pendingActions.removeValue(forKey: id)
        connectingPeripherals.removeValue(forKey: id)
        centralManager.cancelPeripheralConnection(peripheral)
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.state = central.state
            switch central.state {
            case .poweredOn:
                self.startScanning()
            case .poweredOff:
                self.lastError = "Bluetooth is off."
                self.isScanning = false
            case .unauthorized:
                self.lastError = "Bluetooth permission denied."
            case .unsupported:
                self.lastError = "Bluetooth not supported on this device."
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Capture the few fields we need, then hop to the main actor.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let mfg  = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let svc  = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]

        let id = peripheral.identifier
        let rssi = RSSI.intValue

        Task { @MainActor in
            // In debug mode, accept EVERY peripheral (even nameless ones).
            // In normal mode, require it to match the Soundcore filter.
            if !self.debugShowAll {
                guard SoundcoreIdentifiers.isSoundcore(
                    name: name, manufacturerData: mfg, serviceUUIDs: svc) else { return }
            }

            // Build a display name that gives us something to identify on —
            // either the advertised name, or the manufacturer company ID in hex,
            // or the truncated peripheral UUID as a last resort.
            let displayName: String
            if let n = name, !n.isEmpty {
                displayName = n
            } else if let mfg, mfg.count >= 2 {
                let companyID = UInt16(mfg[0]) | (UInt16(mfg[1]) << 8)
                let tag = String(format: "0x%04X", companyID)
                displayName = "Unnamed (\(tag))"
            } else {
                displayName = "Unnamed (\(id.uuidString.prefix(8)))"
            }

            if var entry = self.discovered[id] {
                // Existing entry: update live state + apply EMA to smoothedRSSI.
                let a = self.rssiSmoothingAlpha
                entry.smoothedRSSI = a * Double(rssi) + (1 - a) * entry.smoothedRSSI
                entry.rssi = rssi
                entry.name = displayName
                entry.lastSeen = .now
                entry.manufacturerData = mfg
                entry.advertisedServiceUUIDs = svc ?? []
                entry.peripheral = peripheral
                self.discovered[id] = entry
            } else {
                // First sighting this session. Apply any previously stored
                // calibration for this device so the distance readout is
                // accurate immediately.
                var entry = DiscoveredDevice(
                    id: id,
                    name: displayName,
                    rssi: rssi,
                    smoothedRSSI: Double(rssi),
                    lastSeen: .now,
                    manufacturerData: mfg,
                    advertisedServiceUUIDs: svc ?? [],
                    peripheral: peripheral
                )
                if let stored = self.calibrationCache[id.uuidString] {
                    entry.calibratedTxPowerAt1m = stored
                }
                self.discovered[id] = entry
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        Task { @MainActor in
            // iOS often populates peripheral.name from classic-BT cache on connect.
            self.refreshNameFromPeripheral(peripheral)
            switch self.pendingActions[id] {
            case .identify:
                // Discover EVERYTHING — iOS hides some services but a full scan
                // is still the most informative thing we can do.
                peripheral.discoverServices(nil)
            case .playSound, .none:
                peripheral.discoverServices(SoundcoreIdentifiers.knownServiceUUIDs)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.lastError = "Connect failed: \(error?.localizedDescription ?? "unknown")"
            self.connectingPeripherals.removeValue(forKey: peripheral.identifier)
            self.pendingActions.removeValue(forKey: peripheral.identifier)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.connectingPeripherals.removeValue(forKey: peripheral.identifier)
            self.pendingActions.removeValue(forKey: peripheral.identifier)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        Task { @MainActor in
            if let error {
                if var entry = self.discovered[id] {
                    entry.probeState = .failed(error.localizedDescription)
                    self.discovered[id] = entry
                }
                self.centralManager.cancelPeripheralConnection(peripheral)
                return
            }
            guard let services = peripheral.services else {
                if var entry = self.discovered[id] {
                    entry.probeState = .failed("No services")
                    self.discovered[id] = entry
                }
                self.centralManager.cancelPeripheralConnection(peripheral)
                return
            }

            self.refreshNameFromPeripheral(peripheral)

            let action = self.pendingActions[id]
            switch action {
            case .identify:
                // Discover characteristics for every service we found so the
                // UI can display a full dump. We track how many we expect and
                // finish once they all come back.
                self.pendingServiceCount[id] = services.count
                for service in services {
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            case .playSound, .none:
                for service in services {
                    peripheral.discoverCharacteristics(
                        SoundcoreIdentifiers.findMyCharacteristicUUIDs, for: service)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let id = peripheral.identifier
        let serviceChars = service.characteristics ?? []

        Task { @MainActor in
            let action = self.pendingActions[id]
            switch action {
            case .identify:
                // Accumulate this service, decrement the pending counter,
                // and when we've heard back about all of them, finish the probe.
                var acc = self.probeServices[id] ?? []
                acc.append(service)
                self.probeServices[id] = acc

                let remaining = (self.pendingServiceCount[id] ?? 1) - 1
                self.pendingServiceCount[id] = remaining
                if remaining <= 0 {
                    let allServices = self.probeServices[id] ?? []
                    self.probeServices.removeValue(forKey: id)
                    self.pendingServiceCount.removeValue(forKey: id)
                    self.finishProbe(peripheral, services: allServices)
                }

            case .playSound, .none:
                let targets = Set(SoundcoreIdentifiers.findMyCharacteristicUUIDs)
                // 0x01 is the value many Anker firmware builds accept as "ring".
                // On unsupported models this simply fails without side effects.
                let ringByte = Data([0x01])
                for char in serviceChars where targets.contains(char.uuid) {
                    if char.properties.contains(.write) {
                        peripheral.writeValue(ringByte, for: char, type: .withResponse)
                    } else if char.properties.contains(.writeWithoutResponse) {
                        peripheral.writeValue(ringByte, for: char, type: .withoutResponse)
                    }
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.lastError = "Play sound failed: \(error.localizedDescription)"
            }
            // Disconnect; we only needed the one write.
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }
}
