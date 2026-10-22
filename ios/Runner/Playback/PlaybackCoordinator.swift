import Foundation

enum PlaybackSuspension { case interruption, routeDisconnected, background, backgroundDisabled }
struct PlaybackPolicy {
    var backgroundAudio = false
    var pictureInPicture = false
    func mustPause(for reason: PlaybackSuspension) -> Bool {
        switch reason {
        case .interruption, .routeDisconnected, .backgroundDisabled: return true
        case .background: return !backgroundAudio && !pictureInPicture
        }
    }
}

#if os(iOS)
import AVFoundation
import MediaPlayer
import Flutter
import UIKit

@MainActor
final class PlaybackCoordinator: NativePlayerIntegration {
    private weak var plugin: NativePlayerPlugin?
    private let audio = AudioSessionCoordinator.shared
    private var currentPlayerID: Int?
    private var backgroundAudio = false
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var metadata: [String: Any] = [:]
    private lazy var pip: PictureInPictureCoordinator = {
        let value = PictureInPictureCoordinator { [weak self] in self?.plugin?.host(for: $0)?.playerLayer }
        value.restorePresentation = { [weak self] completion in
            guard let plugin = self?.plugin else { completion(false); return }
            plugin.emitRemoteAction("fullscreen", completion: { result in completion(result as? Bool ?? false) })
        }
        value.onStop = { [weak self] id in
            guard let self else { return }
            self.plugin?.host(for: id)?.pause()
            self.plugin?.emitRemoteAction("stop")
        }
        return value
    }()

    init(plugin: NativePlayerPlugin) {
        self.plugin = plugin
        observe(AVAudioSession.interruptionNotification) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.suspend(.interruption)
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            self?.suspend(.routeDisconnected)
        }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in self?.suspend(.background) }
        observe(AudioSessionCoordinator.ownerChanged) { [weak self] note in
            guard let self, let id = self.currentPlayerID else { return }
            if note.userInfo?["ownerID"] as? String != self.owner(id) {
                self.plugin?.host(for: id)?.pause()
                self.currentPlayerID = nil
                self.backgroundAudio = false
                self.clearNowPlaying()
            }
        }
    }

    private func observe(_ name: Notification.Name, action: @escaping (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { action(note) }
        })
    }
    private func owner(_ id: Int) -> String { "player:\(id)" }

    func willPlay(playerID: Int) throws {
        let previous = currentPlayerID
        try audio.claim(ownerID: owner(playerID), kind: backgroundAudio ? .audio : .video)
        if let previous, previous != playerID { plugin?.host(for: previous)?.pause() }
        currentPlayerID = playerID
        installRemoteCommands()
    }

    func release(playerID: Int) -> Bool {
        // Dart's retained business session must own every active resource.
        // An explicit dispose is always final; PlatformView detach never calls it.
        if pip.ownedPlayerID == playerID { pip.stop() }
        if currentPlayerID == playerID {
            currentPlayerID = nil
            backgroundAudio = false
            audio.release(ownerID: owner(playerID))
            clearNowPlaying()
        }
        return true
    }

    func didEmit(event: [String: Any]) {
        guard let id = event["playerId"] as? Int, id == currentPlayerID,
              audio.ownerID == owner(id), let type = event["type"] as? String else { return }
        switch type {
        case "position":
            if let ms = event["value"] as? Int { metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(ms) / 1000 }
        case "duration":
            if let ms = event["value"] as? Int { metadata[MPMediaItemPropertyPlaybackDuration] = Double(ms) / 1000 }
        case "playing", "playWhenReady":
            metadata[MPNowPlayingInfoPropertyPlaybackRate] = (event["value"] as? Bool == true) ? (plugin?.host(for: id)?.playbackRate ?? 1) : 0
        default: return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = metadata
    }

    func handle(method: String, arguments args: [String: Any], completion: @escaping FlutterResult) -> Bool {
        switch method {
        case "systemPlaybackActive": completion(backgroundAudio || pip.activePlayerID != nil)
        case "canDrawOverlays": completion(PictureInPictureCoordinator.supported)
        case "requestOverlayPermission": completion(false)
        case "startFloating":
            guard let id = args["playerId"] as? Int else { completion(failure("missing_player")); return true }
            pip.start(playerID: id) { [weak self] result in
                switch result {
                case .success:
                    self?.updateMetadata(args)
                    self?.installRemoteCommands()
                    completion(nil)
                case .failure: completion(self?.failure("pip_unavailable"))
                }
            }
        case "swapFloatingPlayer":
            do {
                guard let id = args["playerId"] as? Int else { throw NSError(domain: "fqapp", code: 1) }
                try pip.swap(playerID: id)
                try willPlay(playerID: id)
                completion(nil)
            } catch { completion(failure("pip_swap_failed")) }
        case "updateFloating": updateMetadata(args); completion(nil)
        case "stopFloating": pip.stop(); completion(nil)
        case "showFloating": completion(nil) // System presentation is already confirmed by didStart.
        case "startListenForeground":
            // Speech already claimed its unique generation owner. Metadata
            // publication must never claim a player or resume paused speech.
            backgroundAudio = true
            updateMetadata(args)
            installRemoteCommands()
            completion(nil)
        case "stopListenForeground":
            backgroundAudio = false
            if UIApplication.shared.applicationState != .active { suspend(.backgroundDisabled) }
            clearNowPlaying()
            completion(nil)
        default: return false
        }
        return true
    }

    private func failure(_ code: String) -> FlutterError { FlutterError(code: code, message: "System playback unavailable", details: nil) }
    private func suspend(_ reason: PlaybackSuspension) {
        let policy = PlaybackPolicy(backgroundAudio: backgroundAudio, pictureInPicture: pip.activePlayerID != nil)
        guard policy.mustPause(for: reason) else { return }
        if let id = currentPlayerID { plugin?.host(for: id)?.pause() }
        plugin?.emitBecomingNoisy()
        if reason == .backgroundDisabled { clearNowPlaying() }
    }

    private func updateMetadata(_ args: [String: Any]) {
        if let title = args["title"] as? String { metadata[MPMediaItemPropertyTitle] = title }
        if let episode = args["episode"] as? String { metadata[MPMediaItemPropertyAlbumTitle] = episode }
        if let ms = args["positionMs"] as? Int { metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(ms) / 1000 }
        if let ms = args["durationMs"] as? Int { metadata[MPMediaItemPropertyPlaybackDuration] = Double(ms) / 1000 }
        if let playing = args["playing"] as? Bool { metadata[MPNowPlayingInfoPropertyPlaybackRate] = playing ? (args["speed"] as? Double ?? 1) : 0 }
        let remote = MPRemoteCommandCenter.shared()
        if let previous = args["hasPrev"] as? Bool { remote.previousTrackCommand.isEnabled = previous }
        if let next = args["hasNext"] as? Bool { remote.nextTrackCommand.isEnabled = next }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = metadata
    }

    static func remoteActions(for center: MPRemoteCommandCenter) -> [(MPRemoteCommand, String)] {
        [(center.togglePlayPauseCommand, "playPause"), (center.playCommand, "play"),
         (center.pauseCommand, "pause"), (center.previousTrackCommand, "prev"),
         (center.nextTrackCommand, "next"), (center.stopCommand, "stop")]
    }

    private func installRemoteCommands() {
        guard remoteTargets.isEmpty else { return }
        for (command, action) in Self.remoteActions(for: .shared()) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.plugin?.emitRemoteAction(action) }
                return .success
            }
            remoteTargets.append((command, target))
        }
    }
    private func clearNowPlaying() {
        metadata.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for (command, token) in remoteTargets { command.removeTarget(token); command.isEnabled = false }
        remoteTargets.removeAll()
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for (command, token) in remoteTargets { command.removeTarget(token) }
    }
}
#endif
