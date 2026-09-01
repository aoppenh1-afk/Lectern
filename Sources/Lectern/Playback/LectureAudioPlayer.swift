import AVFoundation
import Observation
import SwiftData

/// Minimal playback surface for jumping a transcript click back into audio.
@MainActor
@Observable
final class LectureAudioPlayer {
    private(set) var activeLectureID: PersistentIdentifier?
    private(set) var isPlaying = false

    private var player: AVPlayer?

    /// Starts playback of `lecture`'s recording from `seconds`, or stops it
    /// if this lecture is already playing.
    func play(_ lecture: Lecture, from seconds: Double) {
        if isActive(lecture) {
            stop()
            return
        }

        guard let recording = lecture.recording, !recording.isPruned else { return }

        stop()
        let newPlayer = AVPlayer(url: URL(fileURLWithPath: recording.filePath))
        let clamped = max(0, seconds)
        newPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        newPlayer.play()
        player = newPlayer
        activeLectureID = lecture.persistentModelID
        isPlaying = true
    }

    func stop() {
        player?.pause()
        player = nil
        activeLectureID = nil
        isPlaying = false
    }

    func isActive(_ lecture: Lecture) -> Bool {
        activeLectureID == lecture.persistentModelID && isPlaying
    }
}
