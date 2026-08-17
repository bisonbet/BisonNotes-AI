//
//  LocationManager.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//

import Foundation
import CoreLocation
import SwiftUI

@MainActor
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

        // Initialize with notDetermined and let the delegate callback update it.
        locationStatus = .notDetermined

        // Defer the initial status read until after CLLocationManager has been
        // configured, while keeping all access on its required actor.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.locationStatus = self.locationManager.authorizationStatus
        }
    }

    func requestLocationPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            if locationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            locationError = "Location access denied. Please enable in Settings."
        case .authorizedWhenInUse, .authorizedAlways:
            startLocationUpdates()
        @unknown default:
            locationError = "Unknown authorization status"
        }
    }

    /// `CLLocationManager.locationServicesEnabled()` can block its caller, so
    /// Apple documents it as unsafe to call from the main thread. Read it on a
    /// background executor and resume the main-actor flow with the result.
    private nonisolated static func locationServicesEnabled() async -> Bool {
        await Task.detached(priority: .utility) {
            CLLocationManager.locationServicesEnabled()
        }.value
    }

    func startLocationUpdates() {
        Task { @MainActor [weak self] in
            guard await Self.locationServicesEnabled() else {
                self?.locationError = "Location services are disabled on this device"
                return
            }
            self?.performStartLocationUpdates()
        }
    }

    private func performStartLocationUpdates() {
        let status = locationManager.authorizationStatus
        locationStatus = status

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // Only request a one-time location update to avoid continuous battery drain
            // Do NOT use startUpdatingLocation() as it runs continuously
            locationManager.requestLocation()
            isLocationEnabled = true
            locationError = nil
        case .denied, .restricted:
            locationError = "Location access denied. Please enable in Settings."
        case .notDetermined:
            // Don't request permission here - let the authorization callback handle it
            locationError = "Location permission not determined"
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
        Task { @MainActor [weak self] in
            guard await Self.locationServicesEnabled() else {
                self?.locationError = "Location services are disabled on this device"
                return
            }
            self?.performRequestOneTimeLocation()
        }
    }

    private func performRequestOneTimeLocation() {
        let status = locationManager.authorizationStatus
        locationStatus = status

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // Location manager methods must be called on main queue
            locationManager.requestLocation()
            locationError = nil
        case .denied, .restricted:
            locationError = "Location access denied. Please enable in Settings."
        case .notDetermined:
            // Don't request permission here - let the authorization callback handle it
            locationError = "Location permission not determined"
        @unknown default:
            locationError = "Unknown location authorization status"
        }
    }

    // MARK: - One-time location request with completion handler

    private var locationCompletionHandlers: [(CLLocation?) -> Void] = []

    func requestCurrentLocation(completion: @escaping (CLLocation?) -> Void) {
        // Add completion handler to the list
        locationCompletionHandlers.append(completion)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await Self.locationServicesEnabled() else {
                self.locationError = "Location services are disabled on this device"
                self.locationCompletionHandlers.forEach { $0(nil) }
                self.locationCompletionHandlers.removeAll()
                return
            }
            self.proceedWithLocationRequest()
        }
    }

    private func proceedWithLocationRequest() {
        let status = locationManager.authorizationStatus
        locationStatus = status

        switch status {
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

    @MainActor private static var geocodingCache: [String: String] = [:]
    @MainActor private static var lastGeocodingRequest: Date = Date.distantPast
    private static let geocodingDelay: TimeInterval = 1.2 // 1.2 seconds between requests to stay under 50/minute
    @MainActor private static var pendingGeocodingRequests: [String: [(String?) -> Void]] = [:]

    @MainActor
    func reverseGeocodeLocation(_ location: CLLocation, completion: @escaping (String?) -> Void) {
        // Create a cache key based on location (rounded to ~100m precision to allow cache hits)
        let lat = round(location.coordinate.latitude * 1000) / 1000
        let lon = round(location.coordinate.longitude * 1000) / 1000
        let cacheKey = "\(lat),\(lon)"

        // Check cache first
        if let cachedAddress = Self.geocodingCache[cacheKey] {
            AppLog.shared.recording("LocationManager: Using cached address", level: .debug)
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
                        AppLog.shared.recording("LocationManager: Reverse geocoding error: \(error)", level: .error)
                        // Call all pending completions with nil
                        pendingCompletions.forEach { $0(nil) }
                        return
                    }

                    guard let placemark = placemarks?.first else {
                        AppLog.shared.recording("LocationManager: No placemark found", level: .debug)
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

    @MainActor static func clearGeocodingCache() {
        geocodingCache.removeAll()
        pendingGeocodingRequests.removeAll()
        AppLog.shared.recording("LocationManager: Geocoding cache and pending requests cleared")
    }

    @MainActor static func getGeocodingCacheSize() -> Int {
        return geocodingCache.count
    }

    @MainActor static func getGeocodingCacheStats() -> (cached: Int, pending: Int) {
        return (geocodingCache.count, pendingGeocodingRequests.count)
    }

    // Method to check if we're currently rate limited
    @MainActor static func isRateLimited() -> Bool {
        let timeSinceLastRequest = Date().timeIntervalSince(lastGeocodingRequest)
        return timeSinceLastRequest < geocodingDelay
    }

    // Method to get time until next request is allowed
    @MainActor static func timeUntilNextRequest() -> TimeInterval {
        let timeSinceLastRequest = Date().timeIntervalSince(lastGeocodingRequest)
        return max(0, geocodingDelay - timeSinceLastRequest)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let snapshot = CLLocation(
            coordinate: location.coordinate,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            course: location.course,
            speed: location.speed,
            timestamp: location.timestamp
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            currentLocation = snapshot
            locationError = nil

            // Call any pending completion handlers
            if !locationCompletionHandlers.isEmpty {
                locationCompletionHandlers.forEach { $0(snapshot) }
                locationCompletionHandlers.removeAll()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let errorCode = (error as? CLError)?.code
        let errorDescription = error.localizedDescription

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch errorCode {
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
                locationError = "Location error: \(errorDescription)"
            }

            isLocationEnabled = false

            // Call any pending completion handlers with nil (indicating failure)
            if !locationCompletionHandlers.isEmpty {
                locationCompletionHandlers.forEach { $0(nil) }
                locationCompletionHandlers.removeAll()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        Task { @MainActor [weak self] in
            guard let self else { return }
            locationStatus = status

            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                startLocationUpdates()

                // If we have pending completion handlers, trigger a location request
                if !locationCompletionHandlers.isEmpty {
                    locationManager.requestLocation()
                }
            case .denied, .restricted:
                locationError = "Location access denied. Please enable in Settings."
                isLocationEnabled = false

                // Call any pending completion handlers with nil
                if !locationCompletionHandlers.isEmpty {
                    locationCompletionHandlers.forEach { $0(nil) }
                    locationCompletionHandlers.removeAll()
                }
            case .notDetermined:
                locationError = nil
                isLocationEnabled = false
            @unknown default:
                locationError = "Unknown authorization status"
                isLocationEnabled = false

                // Call any pending completion handlers with nil
                if !locationCompletionHandlers.isEmpty {
                    locationCompletionHandlers.forEach { $0(nil) }
                    locationCompletionHandlers.removeAll()
                }
            }
        }
    }
}

// MARK: - Location Data Structure

// LocationData is now defined in Shared/LocationData.swift
