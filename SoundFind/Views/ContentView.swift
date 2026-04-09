import SwiftUI
import SwiftData

/// Root screen. Apple Find My-style layout:
///   - Map fills the background.
///   - A bottom sheet lists known + in-range Soundcore devices.
///   - Selecting a device opens a full detail / radar screen.
struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var location: LocationManager
    @Environment(\.modelContext) private var modelContext

    @State private var viewModel: DeviceViewModel?
    @State private var selectedDeviceID: UUID?
    @State private var sheetDetent: PresentationDetent = .medium

    var body: some View {
        ZStack {
            MapView(
                stored: viewModel?.rows ?? [],
                live: Array(bluetooth.discovered.values),
                userLocation: location.lastLocation?.coordinate,
                selectedDeviceID: $selectedDeviceID
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                header
                if let err = bluetooth.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding(.horizontal)
                }
                Spacer()
            }
        }
        .sheet(isPresented: .constant(true)) {
            DeviceListView(
                storedRows: viewModel?.rows ?? [],
                liveDevices: bluetooth.discovered,
                stableOrder: bluetooth.stableOrder,
                isDebugMode: bluetooth.debugShowAll,
                onSelect: { selectedDeviceID = $0 },
                onIdentify: { bluetooth.identify($0) },
                onFavorite: { viewModel?.toggleFavorite($0) },
                onForget: { viewModel?.forget($0) }
            )
            .presentationDetents([.fraction(0.18), .medium, .large], selection: $sheetDetent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(true)
        }
        .sheet(item: Binding(
            get: { selectedDeviceID.map { IdentifiableUUID(id: $0) } },
            set: { selectedDeviceID = $0?.id }
        )) { wrapped in
            DeviceDetailView(deviceID: wrapped.id)
                .environmentObject(bluetooth)
                .environmentObject(location)
        }
        .task {
            if viewModel == nil {
                let vm = DeviceViewModel(context: modelContext)
                vm.bind(bluetooth: bluetooth, location: location)
                viewModel = vm
            }
            location.requestPermission()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SoundFind")
                    .font(.title2.weight(.bold))
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(bluetooth.debugShowAll ? .orange : .secondary)
            }
            Spacer()
            Button {
                bluetooth.toggleDebugMode()
            } label: {
                Image(systemName: bluetooth.debugShowAll ? "eye.fill" : "eye.slash")
                    .font(.title3)
                    .foregroundStyle(bluetooth.debugShowAll ? .orange : .secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel(bluetooth.debugShowAll ? "Show only Soundcore" : "Show all BLE devices")
            Button {
                bluetooth.toggleScanning()
            } label: {
                Image(systemName: bluetooth.isScanning ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var statusLine: String {
        if bluetooth.debugShowAll {
            return "Debug: showing all BLE devices"
        }
        return bluetooth.isScanning ? "Scanning…" : "Paused"
    }
}

private struct IdentifiableUUID: Identifiable {
    let id: UUID
}
