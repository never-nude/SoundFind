import SwiftUI
import MapKit

/// Main map. Pins every known last-seen location and highlights devices
/// currently in range.
struct MapView: View {
    let stored: [DeviceViewModel.Row]
    let live: [DiscoveredDevice]
    let userLocation: CLLocationCoordinate2D?
    @Binding var selectedDeviceID: UUID?

    @State private var cameraPosition: MapCameraPosition = .automatic

    private var annotations: [Annotation] {
        var out: [Annotation] = []
        let liveIDs = Set(live.map { $0.id })
        for row in stored {
            guard let coord = row.lastCoordinate else { continue }
            out.append(Annotation(
                id: row.id,
                name: row.name,
                coordinate: coord,
                isLive: liveIDs.contains(row.id),
                lastSeen: row.lastSeen
            ))
        }
        return out
    }

    var body: some View {
        Map(position: $cameraPosition, selection: $selectedDeviceID) {
            UserAnnotation()

            ForEach(annotations) { ann in
                Marker(ann.name, systemImage: ann.isLive ? "dot.radiowaves.left.and.right" : "headphones",
                       coordinate: ann.coordinate)
                    .tint(ann.isLive ? .green : .gray)
                    .tag(ann.id)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onAppear {
            if let userLocation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: userLocation,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }

    struct Annotation: Identifiable {
        let id: UUID
        let name: String
        let coordinate: CLLocationCoordinate2D
        let isLive: Bool
        let lastSeen: Date
    }
}
