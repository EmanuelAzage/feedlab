import Foundation

/// One playable entry in a feed manifest.
///
/// Deliberately free of AVFoundation: the playback engine turns a `FeedItem` into an
/// `AVURLAsset`, but the content layer only describes what exists and under what terms.
struct FeedItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let url: URL
    let source: ContentSource

    /// Derived from the URL rather than declared in JSON.
    ///
    /// A declared field can disagree with reality; the URL cannot. This matters because
    /// ABR metrics (`indicatedBitrate`, bitrate switch count) are only meaningful for
    /// `.hls` — a progressive MP4 has no ladder to switch within, and those access-log
    /// fields stay flat. Aggregations must be able to exclude progressive items.
    var streamFormat: StreamFormat {
        // Not `url.pathExtension`: the Unified Streaming URLs end in `.ism/.m3u8`, whose
        // last path component is the dotfile-looking ".m3u8". Foundation reports an empty
        // extension for that, which would misclassify a real HLS stream as progressive.
        url.lastPathComponent.hasSuffix(".m3u8") ? .hls : .progressive
    }
}

/// How the media is delivered. Determines which QoE metrics are meaningful.
enum StreamFormat: String, Hashable, Sendable {
    /// Multi-variant HLS with a bitrate ladder. All metrics apply.
    case hls
    /// Single-rendition progressive file. No ABR, so bitrate-switch metrics are not applicable.
    case progressive
}
