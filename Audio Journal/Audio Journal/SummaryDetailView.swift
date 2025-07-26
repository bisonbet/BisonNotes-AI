import SwiftUI
import MapKit
import CoreLocation

struct SummaryDetailView: View {
    let recording: RecordingFile
    let summaryData: SummaryData
    @Environment(\.dismiss) private var dismiss
    @State private var locationAddress: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Map Section
                if let locationData = recording.locationData {
                    VStack {
                        Map(position: .constant(.region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude),
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        )))) {
                            Marker("Recording Location", coordinate: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude))
                                .foregroundStyle(.blue)
                        }
                        .frame(height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                        
                        HStack {
                            Image(systemName: "location.fill")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            Text(locationAddress ?? locationData.coordinateString)
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                        .padding(.bottom)
                    }
                }
                
                // Summary Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text(recording.name)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text(recording.dateString)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Text("Summary created: \(formatDate(summaryData.createdAt))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        
                        // Summary Section
                        if !summaryData.summary.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "text.quote")
                                        .foregroundColor(.accentColor)
                                    Text("Summary")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                
                                Text(summaryData.summary)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .lineSpacing(4)
                            }
                            .padding(.horizontal)
                        }
                        
                        // Tasks Section
                        if !summaryData.tasks.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "checklist")
                                        .foregroundColor(.green)
                                    Text("Tasks")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(summaryData.tasks, id: \.self) { task in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "circle")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                                .padding(.top, 2)
                                            Text(task)
                                                .font(.body)
                                                .foregroundColor(.primary)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        // Reminders Section
                        if !summaryData.reminders.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "bell")
                                        .foregroundColor(.orange)
                                    Text("Reminders")
                                        .font(.headline)
                                        .fontWeight(.semibold)
                                }
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(summaryData.reminders, id: \.self) { reminder in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "bell")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                                .padding(.top, 2)
                                            Text(reminder)
                                                .font(.body)
                                                .foregroundColor(.primary)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let locationData = recording.locationData {
                    let location = CLLocation(latitude: locationData.latitude, longitude: locationData.longitude)
                    let tempLocationManager = LocationManager()
                    tempLocationManager.reverseGeocodeLocation(location) { address in
                        if let address = address {
                            locationAddress = address
                        }
                    }
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
} 