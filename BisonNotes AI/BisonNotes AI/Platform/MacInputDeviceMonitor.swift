#if os(macOS)

import CoreAudio
import Foundation

/// Owns the Core Audio property-listener blocks used to observe microphone
/// connections and system-default input changes.
final class MacInputDeviceMonitor {
    private let onChange: @MainActor @Sendable () -> Void
    // Core Audio can deliver device notifications while AVAudioEngine is
    // reconfiguring its AUHAL on an audio-service queue. Keep the listener
    // callback off the main queue; the recorder explicitly hops to MainActor
    // before touching observable recording state.
    private let listenerQueue = DispatchQueue(
        label: "com.bisonnotes.mac-input-device-monitor",
        qos: .utility
    )
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        addDefaultInputListener()
        addDeviceListListener()
    }

    func stop() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let defaultInputListener {
            var address = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, listenerQueue, defaultInputListener)
            self.defaultInputListener = nil
        }
        if let deviceListListener {
            var address = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, listenerQueue, deviceListListener)
            self.deviceListListener = nil
        }
    }

    private func addDefaultInputListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyChangeOnMain()
        }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )
        if status == noErr {
            defaultInputListener = listener
        } else {
            logListenerError("default Mac input", status: status)
        }
    }

    private func addDeviceListListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyChangeOnMain()
        }
        var address = Self.deviceListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )
        if status == noErr {
            deviceListListener = listener
        } else {
            logListenerError("Mac audio devices", status: status)
        }
    }

    private func logListenerError(_ subject: String, status: OSStatus) {
        let message = NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
        AppLog.shared.audioSession("Could not monitor the \(subject): \(message)", level: .error)
    }

    /// Core Audio invokes property listeners on the supplied audio queue, but
    /// the recorder callback is MainActor-isolated. Schedule only the
    /// Sendable callback here; the task performs the actor hop before calling it.
    private func notifyChangeOnMain() {
        let onChange = onChange
        Task { @MainActor in
            onChange()
        }
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var deviceListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

#endif
