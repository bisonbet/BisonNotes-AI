//
//  LocationManager.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//

import Foundation
import CoreLocation
import SwiftUI

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    
    @Published var currentLocation: CLLocation?
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isLocationEnabled = false
    @Published var locationError: String?
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters // Less demanding than Best
        locationManager.distanceFilter = 10 // Update location when user moves 10 meters
        
        // Check initial authorization status
        locationStatus = locationManager.authorizationStatus
    }
    
    func requestLocationPermission() {
        locationManager.requestWhenInUseAuthorization()
    }
    
    func startLocationUpdates() {
        guard CLLocationManager.locationServicesEnabled() else {
            locationError = "Location services are disabled on this device"
            return
        }
        
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // Try to get a one-time location first, then start continuous updates
            locationManager.requestLocation()
            locationManager.startUpdatingLocation()
            isLocationEnabled = true
            locationError = nil
        case .denied, .restricted:
            locationError = "Location access denied. Please enable in Settings."
        case .notDetermined:
            requestLocationPermission()
        @unknown default:
            locationError = "Unknown location authorization status"
        }
    }
    
    func stopLocationUpdates() {
        locationManager.stopUpdatingLocation()
        isLocationEnabled = false
    }
    
    func getCurrentLocation() -> CLLocation? {
        return currentLocation
    }
    
    func requestOneTimeLocation() {
        guard CLLocationManager.locationServicesEnabled() else {
            locationError = "Location services are disabled on this device"
            return
        }
        
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
            locationError = nil
        case .denied, .restricted:
            locationError = "Location access denied. Please enable in Settings."
        case .notDetermined:
            requestLocationPermission()
        @unknown default:
            locationError = "Unknown location authorization status"
        }
    }
    
    func reverseGeocodeLocation(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Reverse geocoding error: \(error)")
                    completion(nil)
                    return
                }
                
                guard let placemark = placemarks?.first else {
                    completion(nil)
                    return
                }
                
                // Create a formatted address string
                var addressComponents: [String] = []
                
                // Add city
                if let locality = placemark.locality {
                    addressComponents.append(locality)
                }
                
                // Add state/province
                if let administrativeArea = placemark.administrativeArea {
                    addressComponents.append(administrativeArea)
                }
                
                // Add country (only if not USA to avoid redundancy)
                if let country = placemark.country, country != "United States" {
                    addressComponents.append(country)
                }
                
                let formattedAddress = addressComponents.joined(separator: ", ")
                completion(formattedAddress.isEmpty ? nil : formattedAddress)
            }
        }
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        locationError = nil
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let clError = error as? CLError
        
        switch clError?.code {
        case .locationUnknown:
            locationError = "Unable to determine location. Try moving to an area with better GPS signal."
        case .denied:
            locationError = "Location access denied. Please enable in Settings."
        case .network:
            locationError = "Network error while getting location. Check your connection."
        case .headingFailure:
            locationError = "Compass error. Try calibrating your device."
        case .regionMonitoringDenied, .regionMonitoringFailure:
            locationError = "Region monitoring not available."
        case .regionMonitoringSetupDelayed:
            locationError = "Location setup delayed. Please wait."
        default:
            locationError = "Location error: \(error.localizedDescription)"
        }
        
        isLocationEnabled = false
        print("Location error details: \(error)")
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        locationStatus = status
        
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            startLocationUpdates()
        case .denied, .restricted:
            locationError = "Location access denied"
            isLocationEnabled = false
        case .notDetermined:
            locationError = nil
            isLocationEnabled = false
        @unknown default:
            locationError = "Unknown authorization status"
            isLocationEnabled = false
        }
    }
}

// MARK: - Location Data Structure

struct LocationData: Codable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let accuracy: Double?
    let address: String?
    
    init(location: CLLocation) {
        self.id = UUID()
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.timestamp = location.timestamp
        self.accuracy = location.horizontalAccuracy
        self.address = nil // Could be populated with reverse geocoding if needed
    }
    
    var coordinateString: String {
        return String(format: "%.6f, %.6f", latitude, longitude)
    }
    
    var formattedAddress: String {
        return address ?? "Location: \(coordinateString)"
    }
    
    var displayLocation: String {
        if let address = address, !address.isEmpty {
            return address
        }
        return coordinateString
    }
} 