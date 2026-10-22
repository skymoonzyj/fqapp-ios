import Foundation
#if canImport(AVFAudio) && os(iOS)
import AVFAudio
#endif

enum PlaybackKind { case video, audio, speech }

final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    static let ownerChanged = Notification.Name("fqapp.audioSessionOwnerChanged")
    private(set) var ownerID: String?
    private(set) var kind: PlaybackKind?
    private let activate: () throws -> Void
    private let deactivate: () throws -> Void
    private let notifications: NotificationCenter

    init(notifications: NotificationCenter = .default,
         activate: @escaping () throws -> Void = AudioSessionCoordinator.activateSystem,
         deactivate: @escaping () throws -> Void = AudioSessionCoordinator.deactivateSystem) {
        self.notifications = notifications
        self.activate = activate
        self.deactivate = deactivate
    }

    func claim(ownerID: String, kind: PlaybackKind) throws {
        guard !ownerID.isEmpty else { throw OwnershipError.emptyOwner }
        try activate()
        let changed = self.ownerID != ownerID
        self.ownerID = ownerID
        self.kind = kind
        if changed {
            notifications.post(name: Self.ownerChanged, object: self, userInfo: ["ownerID": ownerID])
        }
    }
    func release(ownerID: String) {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
        kind = nil
        try? deactivate()
        notifications.post(name: Self.ownerChanged, object: self)
    }

    private enum OwnershipError: Error { case emptyOwner }

    static func activateSystem() throws {
        #if canImport(AVFAudio) && os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        #endif
    }
    static func deactivateSystem() throws {
        #if canImport(AVFAudio) && os(iOS)
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
