import AVFoundation
import Foundation

/// Configures the process-wide audio session for feed playback.
///
/// Not cosmetic. The default category is `.soloAmbient`, which is silenced by the ringer
/// switch — and a silenced session can mean the audio path does no work at all. Since audio
/// decode is part of the workload being measured, leaving the default risks measuring a
/// video-only pipeline on a muted device and a full one otherwise, which would make runs
/// differ for a reason that has nothing to do with the arm under test.
///
/// `.playback` with `.moviePlayback` mode: plays regardless of the ringer switch, which is
/// both the feed convention and the only way to hold the workload constant across runs.
enum AudioSessionConfigurator {
    static func configureForFeedPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal: video still plays. Logged rather than swallowed because it changes
            // what a subsequent measurement means.
            Log.playback.error(
                "Audio session configuration failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
