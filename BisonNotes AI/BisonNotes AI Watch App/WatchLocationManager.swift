//
//  WatchLocationManager.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/21/25.
//

import Foundation
@preconcurrency import CoreLocation
import Combine

/// Location manager for Apple Watch to collect location data during recordings
@MainActor
class WatchLocationManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentLocation: CLLocation?
    @Published var isLocationAvailable: Bool = false
    @Published var locationError: String?
    
    // MARK: - Private Properties
    private let locationManager = CLLocationManager()
    private var locationCompletion: ((CLLocation?) -> Void)?
    private var isRequestingLocation = false
    
    override init() {
        super.init()
        setupLocationManager()
    }
    
    // MARK: - Setup
    
    private func setupLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10 // Update every 10 meters
        
        // Don't access authorizationStatus immediately - wait for delegate callback
        // The delegate will be called automatically with current status
    }
    
    // MARK: - Public Methods
    
    /// Request location permission from user
    func requestLocationPermission() {
        print("📍⌚ Requesting location permission on watch...")
        locationManager.requestWhenInUseAuthorization()
    }
    
    /// Get current location for recording
    func getCurrentLocation(completion: @escaping (CLLocation?) -> Void) {
        guard isLocationAvailable else {
            print("📍⌚ Location not available")
            completion(nil)
            return
        }
        
        // If we have a recent location (less than 30 seconds old), use it
        if let currentLocation = currentLocation,
           currentLocation.timestamp.timeIntervalSinceNow > -30 {
            print("📍⌚ Using cached location")
            completion(currentLocation)
            return
        }
        
        // Request fresh location
        print("📍⌚ Requesting fresh location...")
        locationCompletion = completion
        isRequestingLocation = true
        locationManager.requestLocation()
    }
    
    /// Start monitoring location changes (for continuous recording)
    func startLocationUpdates() {
        guard isLocationAvailable else { return }
        
        print("📍⌚ Starting location monitoring...")
        locationManager.startUpdatingLocation()
    }
    
    /// Stop monitoring location changes
    func stopLocationUpdates() {
        print("📍⌚ Stopping location monitoring...")
        locationManager.stopUpdatingLocation()
        isRequestingLocation = false
        locationCompletion = nil
    }
    
    // MARK: - Private Methods
    
    private func updateLocationAvailability() {
        // Check location services availability on background queue to avoid main thread warning
        Task.detached {
            let servicesEnabled = CLLocationManager.locationServicesEnabled()
            await MainActor.run {
                self.isLocationAvailable = (self.authorizationStatus == .authorizedWhenInUse || self.authorizationStatus == .authorizedAlways) && servicesEnabled
                print("📍⌚ Location availability updated: \(self.isLocationAvailable)")
            }
        }
    }
    
    private func handleLocationUpdate(_ location: CLLocation) {
        currentLocation = location
        
        if isRequestingLocation {
            locationCompletion?(location)
            locationCompletion = nil
            isRequestingLocation = false
        }
        
        print("📍⌚ Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude), accuracy: \(location.horizontalAccuracy)m")
    }
    
    private func handleLocationError(_ error: Error) {
        locationError = error.localizedDescription
        
        if isRequestingLocation {
            locationCompletion?(nil)
            locationCompletion = nil
            isRequestingLocation = false
        }
        
        print("📍⌚ Location error: \(error.localizedDescription)")
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchLocationManager: CLLocationManagerDelegate {
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Filter out invalid or inaccurate locations
        guard location.horizontalAccuracy < 100 && location.horizontalAccuracy > 0 else {
            print("📍⌚ Location accuracy too low: \(location.horizontalAccuracy)m")
            return
        }
        
        Task { @MainActor in
            handleLocationUpdate(location)
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            handleLocationError(error)
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("📍⌚ Location authorization changed to: \(status.rawValue)")
        
        Task { @MainActor in
            authorizationStatus = status
            updateLocationAvailability()
            
            // If permission was granted, get initial location
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}

// LocationData is defined in Shared/WatchRecordingMessage.swift