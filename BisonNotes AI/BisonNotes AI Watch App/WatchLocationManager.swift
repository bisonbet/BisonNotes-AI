//
//  WatchLocationManager.swift
//  BisonNotes AI Watch App
//
//  Created by Claude on 8/21/25.
//

import Foundation
@preconcurrency import CoreLocation
import Combine
import os.log

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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bisonnotes.watchapp", category: "Location")
    
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
        logger.debug("Requesting location permission on watch")
        locationManager.requestWhenInUseAuthorization()
    }
    
    /// Get current location for recording
    func getCurrentLocation(completion: @escaping (CLLocation?) -> Void) {
        guard isLocationAvailable else {
            logger.debug("Location not available")
            completion(nil)
            return
        }
        
        // If we have a recent location (less than 30 seconds old), use it
        if let currentLocation = currentLocation,
           currentLocation.timestamp.timeIntervalSinceNow > -30 {
            logger.debug("Using cached location")
            completion(currentLocation)
            return
        }
        
        // Request fresh location
        logger.debug("Requesting fresh location")
        locationCompletion = completion
        isRequestingLocation = true
        locationManager.requestLocation()
    }
    
    /// Start monitoring location changes (for continuous recording)
    func startLocationUpdates() {
        guard isLocationAvailable else { return }
        
        logger.debug("Starting location monitoring")
        locationManager.startUpdatingLocation()
    }
    
    /// Stop monitoring location changes
    func stopLocationUpdates() {
        logger.debug("Stopping location monitoring")
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
                self.logger.debug("Location availability updated: \(self.isLocationAvailable, privacy: .public)")
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
        
        logger.debug("Location updated, accuracy: \(location.horizontalAccuracy, privacy: .public)m")
    }
    
    private func handleLocationError(_ error: Error) {
        locationError = error.localizedDescription
        
        if isRequestingLocation {
            locationCompletion?(nil)
            locationCompletion = nil
            isRequestingLocation = false
        }
        
        logger.error("Location error: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchLocationManager: CLLocationManagerDelegate {
    
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        // Filter out invalid or inaccurate locations
        guard location.horizontalAccuracy < 100 && location.horizontalAccuracy > 0 else {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bisonnotes.watchapp", category: "Location").debug("Location accuracy too low: \(location.horizontalAccuracy, privacy: .public)m")
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
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bisonnotes.watchapp", category: "Location").debug("Location authorization changed to: \(status.rawValue, privacy: .public)")
        
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