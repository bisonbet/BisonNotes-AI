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
                    // Only request a one-time location update to avoid continuous battery drain
                    // Do NOT use startUpdatingLocation() as it runs continuously
                    self.locationManager.requestLocation()
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
    
    // MARK: - One-time location request with completion handler
    
    private var locationCompletionHandlers: [(CLLocation?) -> Void] = []
    
    func requestCurrentLocation(completion: @escaping (CLLocation?) -> Void) {
        // Add completion handler to the list
        locationCompletionHandlers.append(completion)
        
        // Check location services availability on background queue to avoid UI blocking
        DispatchQueue.global(qos: .utility).async {
            let servicesEnabled = CLLocationManager.locationServicesEnabled()
            
            DispatchQueue.main.async {
                guard servicesEnabled else {
                    self.locationError = "Location services are disabled on this device"
                    // Call all completion handlers with nil
                    self.locationCompletionHandlers.forEach { $0(nil) }
                    self.locationCompletionHandlers.removeAll()
                    return
                }
                
                // Now proceed with authorization check
                self.proceedWithLocationRequest()
            }
        }
    }
    
    private func proceedWithLocationRequest() {
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // If we already have a recent location (less than 30 seconds old), use it
            if let currentLoc = currentLocation,
               Date().timeIntervalSince(currentLoc.timestamp) < 30 {
                // Call all completion handlers with current location
                locationCompletionHandlers.forEach { $0(currentLoc) }
                locationCompletionHandlers.removeAll()
            } else {
                // Request a fresh location
                locationManager.requestLocation()
            }
        case .denied, .restricted:
            locationError = "Location access denied. Please enable in Settings."
            // Call all completion handlers with nil
            locationCompletionHandlers.forEach { $0(nil) }
            locationCompletionHandlers.removeAll()
        case .notDetermined:
            // Request permission first
            locationManager.requestWhenInUseAuthorization()
            // Don't call completion handlers yet - wait for authorization response
        @unknown default:
            locationError = "Unknown location authorization status"
            // Call all completion handlers with nil
            locationCompletionHandlers.forEach { $0(nil) }
            locationCompletionHandlers.removeAll()
        }
    }
    
    // MARK: - Geocoding Cache and Rate Limiting
    
    private static var geocodingCache: [String: String] = [:]
    private static var lastGeocodingRequest: Date = Date.distantPast
    private static let geocodingDelay: TimeInterval = 1.2 // 1.2 seconds between requests to stay under 50/minute
    private static var pendingGeocodingRequests: [String: [(String?) -> Void]] = [:]
    
    func reverseGeocodeLocation(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        // Create a cache key based on location (rounded to ~100m precision to allow cache hits)
        let lat = round(location.coordinate.latitude * 1000) / 1000
        let lon = round(location.coordinate.longitude * 1000) / 1000
        let cacheKey = "\(lat),\(lon)"
        
        // Check cache first
        if let cachedAddress = Self.geocodingCache[cacheKey] {
            print("📍 LocationManager: Using cached address for \(cacheKey)")
            completion(cachedAddress)
            return
        }
        
        // Check if there's already a pending request for this location
        if Self.pendingGeocodingRequests[cacheKey] != nil {
            Self.pendingGeocodingRequests[cacheKey]?.append(completion)
            return
        }
        
        // Initialize pending requests array for this location
        Self.pendingGeocodingRequests[cacheKey] = [completion]
        
        // Rate limiting: ensure we don't make requests too frequently
        let now = Date()
        let timeSinceLastRequest = now.timeIntervalSince(Self.lastGeocodingRequest)
        
        let delay = max(0, Self.geocodingDelay - timeSinceLastRequest)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.lastGeocodingRequest = Date()
            
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                DispatchQueue.main.async {
                    let pendingCompletions = Self.pendingGeocodingRequests[cacheKey] ?? []
                    Self.pendingGeocodingRequests.removeValue(forKey: cacheKey)
                    
                    if let error = error {
                        print("❌ LocationManager: Reverse geocoding error: \(error)")
                        // Call all pending completions with nil
                        pendingCompletions.forEach { $0(nil) }
                        return
                    }
                    
                    guard let placemark = placemarks?.first else {
                        print("⚠️ LocationManager: No placemark found for \(cacheKey)")
                        pendingCompletions.forEach { $0(nil) }
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
                    let finalAddress = formattedAddress.isEmpty ? nil : formattedAddress
                    
                    // Cache the result (even if nil)
                    Self.geocodingCache[cacheKey] = finalAddress ?? "Unknown Location"
                    
                    // Call all pending completions
                    pendingCompletions.forEach { $0(finalAddress) }
                }
            }
        }
    }
    
    // MARK: - Cache Management
    
    static func clearGeocodingCache() {
        geocodingCache.removeAll()
        pendingGeocodingRequests.removeAll()
        print("🧹 LocationManager: Geocoding cache and pending requests cleared")
    }
    
    static func getGeocodingCacheSize() -> Int {
        return geocodingCache.count
    }
    
    static func getGeocodingCacheStats() -> (cached: Int, pending: Int) {
        return (geocodingCache.count, pendingGeocodingRequests.count)
    }
    
    // Method to check if we're currently rate limited
    static func isRateLimited() -> Bool {
        let timeSinceLastRequest = Date().timeIntervalSince(lastGeocodingRequest)
        return timeSinceLastRequest < geocodingDelay
    }
    
    // Method to get time until next request is allowed
    static func timeUntilNextRequest() -> TimeInterval {
        let timeSinceLastRequest = Date().timeIntervalSince(lastGeocodingRequest)
        return max(0, geocodingDelay - timeSinceLastRequest)
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        locationError = nil
        
        // Call any pending completion handlers
        if !locationCompletionHandlers.isEmpty {
            locationCompletionHandlers.forEach { $0(location) }
            locationCompletionHandlers.removeAll()
        }
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
        
        // Call any pending completion handlers with nil (indicating failure)
        if !locationCompletionHandlers.isEmpty {
            locationCompletionHandlers.forEach { $0(nil) }
            locationCompletionHandlers.removeAll()
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        // Ensure UI updates happen on main queue
        DispatchQueue.main.async {
            self.locationStatus = status
            
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.startLocationUpdates()
                
                // If we have pending completion handlers, trigger a location request
                if !self.locationCompletionHandlers.isEmpty {
                    self.locationManager.requestLocation()
                }
            case .denied, .restricted:
                self.locationError = "Location access denied. Please enable in Settings."
                self.isLocationEnabled = false
                
                // Call any pending completion handlers with nil
                if !self.locationCompletionHandlers.isEmpty {
                    self.locationCompletionHandlers.forEach { $0(nil) }
                    self.locationCompletionHandlers.removeAll()
                }
            case .notDetermined:
                self.locationError = nil
                self.isLocationEnabled = false
            @unknown default:
                self.locationError = "Unknown authorization status"
                self.isLocationEnabled = false
                
                // Call any pending completion handlers with nil
                if !self.locationCompletionHandlers.isEmpty {
                    self.locationCompletionHandlers.forEach { $0(nil) }
                    self.locationCompletionHandlers.removeAll()
                }
            }
        }
    }
}

// MARK: - Location Data Structure

// LocationData is now defined in Shared/LocationData.swift 