#if os(macOS)

import CoreAudio
import Foundation

/// Owns the Core Audio property-listener blocks used to observe microphone
/// connections and system-default input changes.
final class MacInputDeviceMonitor {
    private let onChange: () -> Void
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping () -> Void) {
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
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, .main, defaultInputListener)
            self.defaultInputListener = nil
        }
        if let deviceListListener {
            var address = Self.deviceListAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, .main, deviceListListener)
            self.deviceListListener = nil
        }
    }

    private func addDefaultInputListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange()
        }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
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
            self?.onChange()
        }
        var address = Self.deviceListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
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
