import Combine
import Foundation

/// Playback position changes four times a second while a song plays.
/// Keeping it in its own observable object means only the views that actually
/// display time repaint, instead of every list that observes `PlayerViewModel`.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var elapsedSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0

    /// Equal values are dropped: a paused player keeps publishing the same
    /// position, and repainting for that would be pure noise.
    func setElapsed(_ seconds: Double) {
        guard elapsedSeconds != seconds else { return }
        elapsedSeconds = seconds
    }

    func setDuration(_ seconds: Double) {
        guard durationSeconds != seconds else { return }
        durationSeconds = seconds
    }
}
