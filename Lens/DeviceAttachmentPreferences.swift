import Foundation

struct DeviceAttachmentPreferences {
    private enum Key {
        static let lastEmulatorSerial = "lastAttachedEmulatorSerial"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastEmulatorSerial: String? {
        defaults.string(forKey: Key.lastEmulatorSerial)
    }

    func remember(emulatorSerial: String) {
        defaults.set(emulatorSerial, forKey: Key.lastEmulatorSerial)
    }

    func forget(emulatorSerial: String) {
        guard lastEmulatorSerial == emulatorSerial else { return }
        defaults.removeObject(forKey: Key.lastEmulatorSerial)
    }
}
