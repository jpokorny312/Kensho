import Foundation
import PrismCore
#if os(tvOS)
import UIKit
#endif

/// The one real platform difference in starting a session: on Apple TV the
/// panel's HDMI mode must be programmed and settled BEFORE the playlist is
/// handed to the player (an HDR or Dolby Vision variant is validated against
/// the panel's current mode, synchronously, and fails outright against an
/// SDR-parked panel). Other platforms need nothing here.
public protocol DisplayCoordinating {
    /// Returns an object the caller keeps alive for the session's lifetime
    /// (so the criteria can be reset afterwards), or nil when nothing had to
    /// change (SDR source, or the same criteria already active).
    @MainActor func prepare(for session: PrismCoreSession) async -> AnyObject?
}

/// Does nothing. iPhone, iPad, Mac.
public struct NoDisplayCoordination: DisplayCoordinating {
    public init() {}
    @MainActor public func prepare(for session: PrismCoreSession) async -> AnyObject? { nil }
}

#if os(tvOS)
/// Mirrors `PrismCorePlayback.applyDisplayCriteria(for:)` from the Apple TV
/// target.
public struct TVDisplayCoordination: DisplayCoordinating {
    public init() {}

    @MainActor
    public func prepare(for session: PrismCoreSession) async -> AnyObject? {
        guard let choice = await session.displayCriteria,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first?.windows.first else { return nil }
        let controller = DisplayCriteriaController(window: window)
        if controller.apply(choice) == .willSwitch {
            await controller.waitForSwitch()
        }
        return controller
    }
}
#endif
