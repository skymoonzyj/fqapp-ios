import AVFoundation
import Flutter
import MediaPlayer
import UIKit
import XCTest
@testable import Runner

@MainActor
final class PlayerHostTests: XCTestCase {
    func testPlaybackChannelAndReaderShareAwakeOwnership() {
        let plugin = NativePlayerPlugin()
        let reader = ReaderSession(readBrightness: { 0.5 }, writeBrightness: { _ in },
            setAwake: { AwakeCoordinator.shared.set(ownerID: $0, enabled: $1) })
        func player(_ id: String, _ enabled: Bool) {
            plugin.handle(FlutterMethodCall(methodName: "setKeepScreenOn", arguments: ["ownerID": id, "on": enabled])) {
                XCTAssertNil($0)
            }
        }
        defer {
            reader.stop(id: "awake-contract")
            player("page-a", false)
            player("page-b", false)
        }
        reader.start(id: "awake-contract", brightness: -1)
        reader.keepScreenOn(id: "awake-contract", enabled: true)
        player("page-a", true)
        player("page-a", false)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Reader survives old player release")
        player("page-a", true)
        reader.suspend(id: "awake-contract")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Player survives reader suspension")
        reader.stop(id: "awake-contract")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Player survives reader stop")
        player("page-b", true)
        player("page-a", false)
        player("page-a", false)
        player("never-acquired", false)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Late releases cannot clear the newer page")
        player("page-b", false)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Last owner releases idle timer")
    }

    func testEngineDetachReleasesOnlyItsOwnAwakeClaims() {
        let oldPlugin = NativePlayerPlugin()
        let newPlugin = NativePlayerPlugin()
        let engine = FlutterEngine(name: "awake-cleanup-contract")
        guard let registrar = engine.registrar(forPlugin: "awake-cleanup-contract") else {
            XCTFail("Missing test registrar")
            return
        }
        func set(_ plugin: NativePlayerPlugin, _ id: String, _ enabled: Bool) {
            plugin.handle(FlutterMethodCall(methodName: "setKeepScreenOn", arguments: ["ownerID": id, "on": enabled])) {
                XCTAssertNil($0)
            }
        }
        let reader = ReaderSession(readBrightness: { 0.5 }, writeBrightness: { _ in },
            setAwake: { AwakeCoordinator.shared.set(ownerID: $0, enabled: $1) })
        defer {
            oldPlugin.detachFromEngine(for: registrar)
            newPlugin.detachFromEngine(for: registrar)
            reader.stop(id: "engine-cleanup")
            engine.destroyContext()
        }
        reader.start(id: "engine-cleanup", brightness: -1)
        reader.keepScreenOn(id: "engine-cleanup", enabled: true)
        set(oldPlugin, "same-local-id", true)
        set(oldPlugin, "second-page", true)
        set(newPlugin, "same-local-id", true)
        oldPlugin.detachFromEngine(for: registrar)
        oldPlugin.detachFromEngine(for: registrar)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        reader.stop(id: "engine-cleanup")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Other engine's page survives reader and old engine cleanup")
        set(oldPlugin, "same-local-id", false)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Stale engine cannot remove successor's claim")
        set(newPlugin, "same-local-id", false)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Detached engine leaves no leaked claims")
    }

    func testSystemRemoteProducerMapsExplicitPlayAndPause() {
        let center = MPRemoteCommandCenter.shared()
        let mapping = PlaybackCoordinator.remoteActions(for: center)
        func action(_ command: MPRemoteCommand) -> String? {
            mapping.first { $0.0 === command }?.1
        }
        XCTAssertEqual(action(center.playCommand), "play")
        XCTAssertEqual(action(center.pauseCommand), "pause")
        XCTAssertEqual(action(center.togglePlayPauseCommand), "playPause")
        XCTAssertEqual(action(center.previousTrackCommand), "prev")
        XCTAssertEqual(action(center.nextTrackCommand), "next")
        XCTAssertEqual(action(center.stopCommand), "stop")
    }

    func testRestoreWithoutEngineAcknowledgesFailure() {
        let plugin = NativePlayerPlugin()
        var restored: Bool?
        plugin.emitRemoteAction("fullscreen") { restored = $0 as? Bool }
        XCTAssertEqual(restored, false)
    }

    func testPluginDefersActualReleaseWhileSystemOwnerRetainsPlayer() {
        let plugin = NativePlayerPlugin()
        let owner = RetainingPlayerIntegration()
        plugin.integration = owner
        var events = [[String: Any]]()
        _ = plugin.onListen(withArguments: nil) { value in
            if let event = value as? [String: Any] { events.append(event) }
        }
        var identifier: Int?
        plugin.handle(FlutterMethodCall(methodName: "create", arguments: [
            "cdnUrl": "http://127.0.0.1:1/_session/test/media/fixture",
            "keyHex": "", "mediaId": "fixture", "mediaGeneration": "4"
        ])) { reply in identifier = (reply as? [String: Any])?["playerId"] as? Int }
        guard let id = identifier else { XCTFail("Missing player reply"); return }
        plugin.handle(FlutterMethodCall(methodName: "dispose", arguments: ["id": id])) { _ in }
        XCTAssertNotNil(plugin.host(for: id))
        XCTAssertFalse(events.contains { $0["type"] as? String == "released" })
        plugin.releaseRetainedPlayer(id)
        plugin.releaseRetainedPlayer(id)
        XCTAssertNil(plugin.host(for: id))
        XCTAssertEqual(events.filter { $0["type"] as? String == "released" }.count, 1)
    }

    func testCreatedUsesViewHandleAndReleaseEmitsExactlyOnce() {
        var events = [[String: Any]]()
        let host = PlayerHost(id: 71, player: AVPlayer()) { events.append($0) }
        host.startObserving()
        XCTAssertEqual(events.first?["type"] as? String, "created")
        let surface = events.first?["value"] as? [String: Any]
        XCTAssertEqual(surface?["kind"] as? String, "iosView")
        XCTAssertEqual(surface?["playerId"] as? Int, 71)
        XCTAssertFalse(events.contains { $0["type"] as? String == "firstFrame" })
        host.release()
        host.release()
        XCTAssertEqual(events.filter { $0["type"] as? String == "released" }.count, 1)
        XCTAssertNil(host.player.currentItem)
    }

    func testOnlyOneViewOwnsLayerAndOldViewCannotDetachNewView() {
        let host = PlayerHost(id: 71, player: AVPlayer(), emit: { _ in })
        let first = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
        let second = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        host.attach(to: first)
        XCTAssertTrue(host.playerLayer.superlayer === first.layer)
        host.attach(to: second)
        XCTAssertFalse(first.layer.sublayers?.contains(host.playerLayer) ?? false)
        XCTAssertTrue(host.playerLayer.superlayer === second.layer)
        host.detach(from: first)
        XCTAssertTrue(host.playerLayer.superlayer === second.layer)
        host.detach(from: second)
        XCTAssertNil(host.playerLayer.superlayer)
        XCTAssertTrue(host.playerLayer.player === host.player)
        host.attach(to: first)
        XCTAssertTrue(host.playerLayer.superlayer === first.layer)
        host.release()
        XCTAssertNil(host.playerLayer.superlayer)
        XCTAssertNil(host.playerLayer.player)
    }

    func testPauseClearsPlaybackIntentAndRateSurvivesPause() {
        var events = [[String: Any]]()
        let host = PlayerHost(id: 71, player: AVPlayer()) { events.append($0) }
        host.setRate(1.5)
        host.play()
        host.pause()
        XCTAssertFalse(host.playWhenReady)
        XCTAssertEqual(host.playbackRate, 1.5)
        XCTAssertEqual(events.filter { $0["type"] as? String == "playWhenReady" }
            .compactMap { $0["value"] as? Bool }, [true, false])
        host.release()
    }
}

@MainActor
private final class RetainingPlayerIntegration: NativePlayerIntegration {
    func willPlay(playerID: Int) throws {}
    func release(playerID: Int) -> Bool { false }
    func handle(method: String, arguments: [String: Any], completion: @escaping FlutterResult) -> Bool { false }
    func didEmit(event: [String: Any]) {}
}
