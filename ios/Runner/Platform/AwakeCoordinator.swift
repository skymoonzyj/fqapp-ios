import UIKit

/// Each playback/reading owner releases only its own idle-timer request.
public final class AwakeCoordinator {
  public static let shared = AwakeCoordinator()
  private var owners = Set<String>()

  private init() {}

  public func set(ownerID: String, enabled: Bool) {
    guard !ownerID.isEmpty else { return }
    if !Thread.isMainThread {
      DispatchQueue.main.async { self.set(ownerID: ownerID, enabled: enabled) }
      return
    }
    if enabled {
      owners.insert(ownerID)
    } else {
      owners.remove(ownerID)
    }
    UIApplication.shared.isIdleTimerDisabled = !owners.isEmpty
  }
}
