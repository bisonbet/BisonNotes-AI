//
//  LocationDetailView.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//

import SwiftUI
import MapKit

struct LocationDetailView: View {
    let locationData: LocationData
    @Environment(\.dismiss) private var dismiss
    @State private var region: MKCoordinateRegion
    
    init(locationData: LocationData) {
        self.locationData = locationData
        let coordinate = CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude)
        self._region = State(initialValue: MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Map view
                Map(position: .constant(.region(region))) {
                    Marker("Recording Location", coordinate: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude))
                        .foregroundStyle(.blue)
                }
                .frame(height: 300)
                
                // Location details
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Location Details")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                DetailRow(title: "Latitude", value: String(format: "%.6f", locationData.latitude))
                                DetailRow(title: "Longitude", value: String(format: "%.6f", locationData.longitude))
                                DetailRow(title: "Coordinates", value: locationData.coordinateString)
                                
                                if let address = locationData.address, !address.isEmpty {
                                    DetailRow(title: "Location", value: address)
                                }
                                
                                if let accuracy = locationData.accuracy {
                                    DetailRow(title: "Accuracy", value: String(format: "±%.1f meters", accuracy))
                                }
                                
                                DetailRow(title: "Timestamp", value: formatTimestamp(locationData.timestamp))
                            }
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        
                        // Action buttons
                        VStack(spacing: 12) {
                            Button(action: {
                                openInMaps()
                            }) {
                                HStack {
                                    Image(systemName: "map")
                                        .font(.body)
                                    Text("Open in Maps")
                                        .font(.body)
                                        .fontWeight(.medium)
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .cornerRadius(12)
                            }
                            
                            Button(action: {
                                copyCoordinates()
                            }) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                        .font(.body)
                                    Text("Copy Coordinates")
                                        .font(.body)
                                        .fontWeight(.medium)
                                }
                                .foregroundColor(.accentColor)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func openInMaps() {
        let coordinate = CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude)
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.openInMaps(launchOptions: nil)
    }
    
    private func copyCoordinates() {
        UIPasteboard.general.string = locationData.coordinateString
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fontWeight(.medium)
            
            Spacer()
        }
    }
}

#Preview {
    let sampleLocation = LocationData(location: CLLocation(latitude: 37.7749, longitude: -122.4194))
    LocationDetailView(locationData: sampleLocation)
} 