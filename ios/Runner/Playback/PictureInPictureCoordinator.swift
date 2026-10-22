import Foundation

/// Resolves the method channel reply only after the system confirms PiP.
final class PictureInPictureStart {
    private(set) var activePlayerID: Int?
    private var pending: ((Result<Void, Error>) -> Void)?
    private var pendingPlayerID: Int?
    private var requestStart: (() -> Void)?
    var ownedPlayerID: Int? { activePlayerID ?? pendingPlayerID }
    func begin(playerID: Int, requestStart: (() -> Void)? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        guard pending == nil, activePlayerID == nil else {
            completion(.failure(NSError(domain: "fqapp.pip.busy", code: 1)))
            return
        }
        pendingPlayerID = playerID
        self.requestStart = requestStart
        pending = completion
    }
    func possibilityChanged(_ possible: Bool) {
        guard possible, pending != nil, let start = requestStart else { return }
        requestStart = nil
        start()
    }
    func didStart() {
        guard let reply = pending, let id = pendingPlayerID else { return }
        pending = nil
        pendingPlayerID = nil
        requestStart = nil
        activePlayerID = id
        reply(.success(()))
    }
    func didFail(_ error: Error) {
        let reply = pending
        pending = nil
        pendingPlayerID = nil
        requestStart = nil
        reply?(.failure(error))
    }
    func didStop() {
        activePlayerID = nil
        didFail(NSError(domain: "fqapp.pip.cancelled", code: 2))
    }
}

#if os(iOS)
import AVKit

final class PictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    private let state = PictureInPictureStart()
    private let layer: (Int) -> AVPlayerLayer?
    private var controller: AVPictureInPictureController?
    private var requestedStop = false
    private var timeout: DispatchWorkItem?
    private var readiness: NSKeyValueObservation?
    var onStop: ((Int) -> Void)?
    var restorePresentation: ((@escaping (Bool) -> Void) -> Void)?
    var activePlayerID: Int? { state.activePlayerID }
    var ownedPlayerID: Int? { state.ownedPlayerID }
    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    init(layer: @escaping (Int) -> AVPlayerLayer?) { self.layer = layer }

    func start(playerID: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard Self.supported, let playerLayer = layer(playerID),
              controller == nil,
              let pip = AVPictureInPictureController(playerLayer: playerLayer) else {
            completion(.failure(NSError(domain: "fqapp.pip.unavailable", code: 1)))
            return
        }
        requestedStop = false
        controller = pip
        pip.delegate = self
        state.begin(playerID: playerID, requestStart: { [weak pip] in
            pip?.startPictureInPicture()
        }, completion: completion)
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.didFail(NSError(domain: "fqapp.pip.timeout", code: 3))
            self.stop()
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadline)
        // AVKit readiness can arrive asynchronously after controller creation.
        // Keep this controller alive until ready, cancelled or the deadline.
        readiness = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self, self.controller === observed else { return }
                self.state.possibilityChanged(observed.isPictureInPicturePossible)
            }
        }
    }

    func stop() {
        requestedStop = true
        readiness?.invalidate()
        readiness = nil
        timeout?.cancel()
        timeout = nil
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.delegate = nil
            self.controller = nil
            state.didStop()
        }
    }

    // Keep the actual PiP layer alive while an episode changes. AVKit keeps
    // presenting this layer; the incoming host's own layer can attach on return.
    func swap(playerID: Int) throws {
        guard let controller, controller.isPictureInPictureActive,
              let newLayer = layer(playerID) else {
            throw NSError(domain: "fqapp.pip.inactive", code: 4)
        }
        controller.contentSource = AVPictureInPictureController.ContentSource(playerLayer: newLayer)
        state.didStop()
        state.begin(playerID: playerID) { _ in }
        state.didStart()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        readiness?.invalidate()
        readiness = nil
        timeout?.cancel()
        timeout = nil
        state.didStart()
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        readiness?.invalidate()
        readiness = nil
        timeout?.cancel()
        timeout = nil
        state.didFail(error)
        controller?.delegate = nil
        controller = nil
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        readiness?.invalidate()
        readiness = nil
        let id = activePlayerID
        state.didStop()
        controller?.delegate = nil
        controller = nil
        if let id, !requestedStop { onStop?(id) }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard let restorePresentation else { completionHandler(false); return }
        restorePresentation { [weak self] restored in
            self?.requestedStop = restored
            completionHandler(restored)
        }
    }
}
#endif
