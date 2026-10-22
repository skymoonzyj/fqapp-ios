import Flutter
import UIKit

@MainActor
final class PlayerPlatformViewFactory: NSObject, @preconcurrency FlutterPlatformViewFactory {
    private let lookup: (Int) -> PlayerHost?
    init(lookup: @escaping (Int) -> PlayerHost?) { self.lookup = lookup }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        let id = (args as? [String: Any])?["playerId"] as? Int
        return PlayerPlatformView(frame: frame, host: id.flatMap(lookup))
    }
}

@MainActor
final class PlayerPlatformView: NSObject, @preconcurrency FlutterPlatformView {
    private let surface: PlayerSurfaceView
    init(frame: CGRect, host: PlayerHost?) {
        surface = PlayerSurfaceView(frame: frame, host: host)
        super.init()
    }
    func view() -> UIView { surface }
}

@MainActor
private final class PlayerSurfaceView: UIView {
    private weak var host: PlayerHost?
    init(frame: CGRect, host: PlayerHost?) {
        self.host = host
        super.init(frame: frame)
        backgroundColor = .black
        host?.attach(to: self)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        host?.layout(in: self)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { host?.detach(from: self) }
        else { host?.attach(to: self) }
    }
}
