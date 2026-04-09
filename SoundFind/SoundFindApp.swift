import SwiftUI
import SwiftData

@main
struct SoundFindApp: App {
    @StateObject private var bluetoothManager = BluetoothManager()
    @StateObject private var locationManager = LocationManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([StoredDevice.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetoothManager)
                .environmentObject(locationManager)
                .preferredColorScheme(nil) // Respect system (supports dark mode)
        }
        .modelContainer(sharedModelContainer)
    }
}
