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
        
        // Initialize with notDetermined and let the delegate callback update it
        // This avoids accessing authorizationStatus on the main thread during init
        locationStatus = .notDetermined
        
        // Defer authorization status check to avoid potential crashes during init
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            // Check authorization status on a background queue
            DispatchQueue.global(qos: .utility).async {
                let status = self.locationManager.authorizationStatus
                DispatchQueue.main.async {
                    self.locationStatus = status
                }
            }
        }
    }
    
    func requestLocationPermission() {
        // Check current authorization status on background queue to avoid UI blocking
        DispatchQueue.global(qos: .utility).async {
            let currentStatus = self.locationManager.authorizationStatus
            
            DispatchQueue.main.async {
                switch currentStatus {
                case .notDetermined:
                    // Only request if we haven't already requested
                    if self.locationStatus == .notDetermined {
                        // Request authorization on main queue (required by CLLocationManager)
                        self.locationManager.requestWhenInUseAuthorization()
                    }
                case .denied, .restricted:
                    self.locationError = "Location access denied. Please enable in Settings."
                case .authorizedWhenInUse, .authorizedAlways:
                    // Already authorized, start location updates
                    self.startLocationUpdates()
                @unknown default:
                    self.locationError = "Unknown authorization status"
                }
            }
        }
    }
    
    func startLocationUpdates() {
        // Check location services availability on background queue
        DispatchQueue.global(qos: .utility).async {
            let servicesEnabled = CLLocationManager.locationServicesEnabled()
            
            DispatchQueue.main.async {
                guard servicesEnabled else {
                    self.locationError = "Location services are disabled on this device"
                    return
                }
                
                switch self.locationStatus {
                case .authorizedWhenInUse, .authorizedAlways:
                    // Location manager methods must be called on main queue
                    self.locationManager.requestLocation()
                    self.locationManager.startUpdatingLocation()
                    self.isLocationEnabled = true
                    self.locationError = nil
                case .denied, .restricted:
                    self.locationError = "Location access denied. Please enable in Settings."
                case .notDetermined:
                    // Don't request permission here - let the authorization callback handle it
                    self.locationError = "Location permission not determined"
                @unknown default:
                    self.locationError = "Unknown location authorization status"
                }
            }
        }
    }
    
    func stopLocationUpdates() {
        // Ensure location manager methods are called on main queue
        DispatchQueue.main.async {
            self.locationManager.stopUpdatingLocation()
            self.isLocationEnabled = false
        }
    }
    
    func getCurrentLocation() -> CLLocation? {
        return currentLocation
    }
    
    func requestOneTimeLocation() {
        // Check location services availability on background queue
        DispatchQueue.global(qos: .utility).async {
            let servicesEnabled = CLLocationManager.locationServicesEnabled()
            
            DispatchQueue.main.async {
                guard servicesEnabled else {
                    self.locationError = "Location services are disabled on this device"
                    return
                }
                
                switch self.locationStatus {
                case .authorizedWhenInUse, .authorizedAlways:
                    // Location manager methods must be called on main queue
                    self.locationManager.requestLocation()
                    self.locationError = nil
                case .denied, .restricted:
                    self.locationError = "Location access denied. Please enable in Settings."
                case .notDetermined:
                    // Don't request permission here - let the authorization callback handle it
                    self.locationError = "Location permission not determined"
                @unknown default:
                    self.locationError = "Unknown location authorization status"
                }
            }
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
        print("📍 Location authorization changed to: \(status.rawValue)")
        
        // Ensure UI updates happen on main queue
        DispatchQueue.main.async {
            self.locationStatus = status
            
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                print("✅ Location authorized, starting updates")
                self.startLocationUpdates()
            case .denied, .restricted:
                print("❌ Location access denied or restricted")
                self.locationError = "Location access denied. Please enable in Settings."
                self.isLocationEnabled = false
            case .notDetermined:
                print("⏳ Location authorization not determined")
                self.locationError = nil
                self.isLocationEnabled = false
            @unknown default:
                print("⚠️ Unknown location authorization status: \(status.rawValue)")
                self.locationError = "Unknown authorization status"
                self.isLocationEnabled = false
            }
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
    
    init(id: UUID = UUID(), latitude: Double, longitude: Double, timestamp: Date, accuracy: Double?, address: String?) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.accuracy = accuracy
        self.address = address
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