import Foundation

/// Provenance and licensing for a feed item.
///
/// `license` and `attribution` are required by `docs/content-sources.md`: an entry
/// missing either must fail manifest validation rather than silently play. Keeping
/// them on a value type (rather than loose strings on `FeedItem`) means the three
/// facts that must travel together — who made it, under what terms, and the credit
/// line owed — cannot be separated by accident.
struct ContentSource: Hashable, Sendable {
    /// Rights holder or publisher, e.g. "Blender Foundation".
    let name: String
    /// License identifier, e.g. "CC BY 3.0" or "Public domain".
    let license: String
    /// The credit line shown in-app and in the Credits screen.
    let attribution: String
}
