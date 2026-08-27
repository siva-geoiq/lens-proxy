import Foundation

/// A physical iPhone or iPad the user configured by hand.
///
/// Apple exposes no way to set a device's Wi-Fi proxy or install a certificate
/// remotely, so Lens records what the user set up and keeps showing the device while
/// that configuration is live — including after the phone is unplugged, when
/// `devicectl` stops reporting it.
struct GuidedIOSAttachment: Codable, Hashable, Sendable {
    var identifier: String
    var hardwareUDID: String
    var name: String
    var marketingName: String
    var osVersion: String
    /// Learned from the first flow that arrives from the device.
    var boundAddress: String?
}

struct IOSGuidedAttachmentStore {
    private static let key = "guidedIOSAttachments"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [GuidedIOSAttachment] {
        guard let data = defaults.data(forKey: Self.key),
              let attachments = try? JSONDecoder().decode([GuidedIOSAttachment].self, from: data) else { return [] }
        return attachments
    }

    func contains(identifier: String) -> Bool {
        all().contains { $0.identifier == identifier }
    }

    func save(_ attachment: GuidedIOSAttachment) {
        var attachments = all().filter { $0.identifier != attachment.identifier }
        attachments.append(attachment)
        persist(attachments)
    }

    func remove(identifier: String) {
        persist(all().filter { $0.identifier != identifier })
    }

    func bind(identifier: String, address: String) {
        var attachments = all()
        guard let index = attachments.firstIndex(where: { $0.identifier == identifier }) else { return }
        attachments[index].boundAddress = address
        persist(attachments)
    }

    private func persist(_ attachments: [GuidedIOSAttachment]) {
        defaults.set(try? JSONEncoder().encode(attachments), forKey: Self.key)
    }
}
