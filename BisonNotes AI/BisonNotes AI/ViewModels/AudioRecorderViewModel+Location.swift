//
//  AudioRecorderViewModel+Location.swift
//  BisonNotes AI
//
//  Location capture and management during recordings.
//

import Foundation
import CoreLocation

// MARK: - Location Tracking

extension AudioRecorderViewModel {

	func captureCurrentLocation() {
		guard isLocationTrackingEnabled else {
			currentLocationData = nil
			recordingStartLocationData = nil
			return
		}

		recordingStartLocationData = nil

		// Prefer the freshest location available right away
		if let location = locationManager.currentLocation {
			updateCurrentLocationData(with: location)
			if recordingStartLocationData == nil {
				recordingStartLocationData = currentLocationData
			}
		}

		// Always request a fresh location to capture the most accurate coordinate
		locationManager.requestCurrentLocation { [weak self] location in
			guard let self = self else { return }

			DispatchQueue.main.async {
				guard self.isLocationTrackingEnabled else { return }

				guard let location = location else {
					print("⚠️ Failed to capture fresh location for recording start")
					return
				}

				self.updateCurrentLocationData(with: location)
				if self.recordingStartLocationData == nil {
					self.recordingStartLocationData = self.currentLocationData
				}
				print("📍 Location captured for recording: \(location.coordinate.latitude), \(location.coordinate.longitude)")
			}
		}
	}

	func saveLocationData(for recordingURL: URL) {
		guard isLocationTrackingEnabled else {
			print("📍 Location tracking disabled or no location data available")
			return
		}

		// If we never received a location update yet, fall back to the current manager value
		if recordingLocationSnapshot() == nil, let latestLocation = locationManager.currentLocation {
			updateCurrentLocationData(with: latestLocation)
		}

		guard let locationData = recordingLocationSnapshot() else {
			print("📍 No location data available to save for \(recordingURL.lastPathComponent)")
			return
		}

		let locationURL = recordingURL.deletingPathExtension().appendingPathExtension("location")
		do {
			let data = try JSONEncoder().encode(locationData)
			try data.write(to: locationURL)
			print("📍 Location data saved for recording: \(recordingURL.lastPathComponent)")
		} catch {
			print("❌ Failed to save location data: \(error)")
		}
	}

	func setupLocationObservers() {
		locationManager.$currentLocation
			.receive(on: DispatchQueue.main)
			.sink { [weak self] location in
				guard
					let self,
					self.isLocationTrackingEnabled,
					let location
				else { return }

				self.updateCurrentLocationData(with: location)
			}
			.store(in: &cancellables)
	}

	func updateCurrentLocationData(with location: CLLocation) {
		guard location.horizontalAccuracy >= 0 else {
			print("⚠️ Ignoring location with invalid accuracy: \(location.horizontalAccuracy)")
			return
		}

		let newLocationData = LocationData(location: location)

		if let existing = currentLocationData {
			let existingAccuracy = existing.accuracy ?? .greatestFiniteMagnitude
			let newAccuracy = newLocationData.accuracy ?? .greatestFiniteMagnitude

			let isNewer = location.timestamp > existing.timestamp
			let isMoreAccurate = newAccuracy < existingAccuracy

			guard isNewer || isMoreAccurate else {
				return
			}
		}

		currentLocationData = newLocationData

		if isRecording && recordingStartLocationData == nil {
			recordingStartLocationData = newLocationData
		}
	}

	func recordingLocationSnapshot() -> LocationData? {
		recordingStartLocationData ?? currentLocationData
	}

	func resetRecordingLocation() {
		recordingStartLocationData = nil
	}

	func toggleLocationTracking(_ enabled: Bool) {
		isLocationTrackingEnabled = enabled
		UserDefaults.standard.set(enabled, forKey: "isLocationTrackingEnabled")

		if enabled {
			locationManager.requestLocationPermission()
		} else {
			locationManager.stopLocationUpdates()
			currentLocationData = nil
			resetRecordingLocation()
		}

		print("📍 Location tracking \(enabled ? "enabled" : "disabled")")
	}
}
