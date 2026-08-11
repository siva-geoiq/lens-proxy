import Foundation

struct DeviceAttachmentPreferences {
    private enum Key {
        static let lastEmulatorSerial = "lastAttachedEmulatorSerial"
        static let rememberedDeviceIDs = "rememberedAttachedDeviceIDs"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastEmulatorSerial: String? {
        defaults.string(forKey: Key.lastEmulatorSerial)
    }

    var rememberedDeviceIDs: Set<String> {
        var identifiers = Set(defaults.stringArray(forKey: Key.rememberedDeviceIDs) ?? [])
        if let legacyEmulatorSerial = lastEmulatorSerial {
            identifiers.insert(legacyEmulatorSerial)
        }
        return identifiers
    }

    func isRemembered(deviceID: String, transportID: String) -> Bool {
        let identifiers = rememberedDeviceIDs
        return identifiers.contains(deviceID) || identifiers.contains(transportID)
    }

    func remember(deviceID: String) {
        var identifiers = rememberedDeviceIDs
        identifiers.insert(deviceID)
        persist(identifiers)
    }

    func forget(deviceID: String, transportID: String) {
        var identifiers = rememberedDeviceIDs
        identifiers.remove(deviceID)
        identifiers.remove(transportID)
        persist(identifiers)
        if lastEmulatorSerial == deviceID || lastEmulatorSerial == transportID {
            defaults.removeObject(forKey: Key.lastEmulatorSerial)
        }
    }

    func remember(emulatorSerial: String) {
        defaults.set(emulatorSerial, forKey: Key.lastEmulatorSerial)
        remember(deviceID: emulatorSerial)
    }

    func forget(emulatorSerial: String) {
        guard lastEmulatorSerial == emulatorSerial else { return }
        defaults.removeObject(forKey: Key.lastEmulatorSerial)
        var identifiers = rememberedDeviceIDs
        identifiers.remove(emulatorSerial)
        persist(identifiers)
    }

    private func persist(_ identifiers: Set<String>) {
        defaults.set(identifiers.sorted(), forKey: Key.rememberedDeviceIDs)
    }
}
