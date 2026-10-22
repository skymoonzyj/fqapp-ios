import AVFoundation
import UIKit

/// Owns decoding independently of a Flutter route or its platform view.
@MainActor
final class PlayerHost {
    let id: Int
    let player: AVPlayer
    let playerLayer: AVPlayerLayer
    private let emit: ([String: Any]) -> Void
    private var observations = [NSKeyValueObservation]()
    private var timeObserver: Any?
    private var completionObserver: NSObjectProtocol?
    private weak var attachedView: UIView?
    private var observing = false
    private var released = false
    private var firstFrameSent = false
    private(set) var playWhenReady = false
    private(set) var playbackRate: Double = 1

    init(id: Int, player: AVPlayer, emit: @escaping ([String: Any]) -> Void) {
        self.id = id
        self.player = player
        self.playerLayer = AVPlayerLayer(player: player)
        self.emit = emit
        playerLayer.videoGravity = .resizeAspect
    }

    convenience init(id: Int, url: URL, emit: @escaping ([String: Any]) -> Void) {
        self.init(id: id, player: AVPlayer(url: url), emit: emit)
    }

    func startObserving() {
        guard !observing, !released else { return }
        observing = true
        event("created", ["kind": "iosView", "playerId": id])
        observations.append(playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reportFirstFrame() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.reportPlayback() }
        })
        if let item = player.currentItem {
            observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.reportItemStatus() }
            })
            observations.append(item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.reportSize() }
            })
            observations.append(item.observe(\.duration, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.reportDuration() }
            })
            completionObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.released else { return }
                    self.pause()
                    self.event("completed", true)
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            DispatchQueue.main.async {
                guard let self, !self.released, time.seconds.isFinite else { return }
                self.event("position", Int(max(0, time.seconds) * 1000))
            }
        }
    }

    func play() {
        guard !released else { return }
        playWhenReady = true
        event("playWhenReady", true)
        player.playImmediately(atRate: Float(playbackRate))
    }

    func pause() {
        guard !released else { return }
        playWhenReady = false
        player.pause()
        event("playWhenReady", false)
    }

    func seek(milliseconds: Int, completion: @escaping (Bool) -> Void) {
        guard !released else { completion(false); return }
        event("completed", false)
        player.seek(to: CMTime(value: Int64(max(0, milliseconds)), timescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { completed in
            DispatchQueue.main.async { completion(completed) }
        }
    }

    func setRate(_ value: Double) {
        guard !released, value.isFinite, value > 0, value <= 4 else { return }
        playbackRate = value
        if playWhenReady { player.rate = Float(value) }
    }

    func setVolume(_ value: Double) {
        guard !released, value.isFinite else { return }
        player.volume = Float(min(1, max(0, value)))
    }

    func attach(to view: UIView) {
        guard !released else { return }
        playerLayer.removeFromSuperlayer()
        attachedView = view
        view.layer.addSublayer(playerLayer)
        layout(in: view)
    }

    func layout(in view: UIView) {
        guard attachedView === view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = view.bounds
        CATransaction.commit()
    }

    func detach(from view: UIView) {
        // A delayed disposal of the old Flutter view must not detach its new host.
        guard attachedView === view else { return }
        attachedView = nil
        playerLayer.removeFromSuperlayer()
    }

    func release() {
        guard !released else { return }
        released = true
        observations.removeAll()
        if let token = completionObserver { NotificationCenter.default.removeObserver(token) }
        completionObserver = nil
        if let token = timeObserver { player.removeTimeObserver(token) }
        timeObserver = nil
        player.pause()
        playerLayer.removeFromSuperlayer()
        attachedView = nil
        playerLayer.player = nil
        player.replaceCurrentItem(with: nil)
        emit(["playerId": id, "type": "released"])
    }

    private func event(_ type: String, _ value: Any) {
        guard !released else { return }
        emit(["playerId": id, "type": type, "value": value])
    }

    private func reportFirstFrame() {
        guard !released, playerLayer.isReadyForDisplay, !firstFrameSent else { return }
        firstFrameSent = true
        event("firstFrame", true)
    }

    private func reportPlayback() {
        event("playing", player.timeControlStatus == .playing)
        event("buffering", player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    }

    private func reportItemStatus() {
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            // AVFoundation error descriptions can embed source URLs/capabilities.
            event("error", ["message": "Media playback failed", "errorCode": item.error.map { ($0 as NSError).code } ?? -1])
        }
    }

    private func reportDuration() {
        guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else { return }
        event("duration", Int(seconds * 1000))
    }

    private func reportSize() {
        guard !released, let size = player.currentItem?.presentationSize,
              size.width > 0, size.height > 0 else { return }
        // AVPlayerLayer applies the asset's preferred transform itself.
        emit(["playerId": id, "type": "videoSize", "width": Int(size.width),
              "height": Int(size.height), "rotationCorrection": 0])
    }
}
