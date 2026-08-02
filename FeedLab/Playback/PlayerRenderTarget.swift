import Foundation

/// A surface a borrowed player can render into.
///
/// Exists so the coordinator can bind and unbind players without naming `FeedCell`, and so
/// the ordering rule below has one place to be stated.
///
/// **Ordering rule:** unbind (`attachPlayer(nil)`) on the main actor *before* the player is
/// released to the pool. Releasing first leaves the old layer holding a player that another
/// cell is about to adopt, and the visible result is one item's video appearing inside
/// another item's cell — a real, screenshot-able bug this design is shaped to avoid.
@MainActor
protocol PlayerRenderTarget: AnyObject {
    func attachPlayer(_ player: (any PlayerProviding)?)
}
