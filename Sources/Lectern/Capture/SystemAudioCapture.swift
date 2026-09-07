import CoreMedia
import Foundation
import ScreenCaptureKit
@preconcurrency import AVFAudio

/// Captures the Mac's system audio mix through ScreenCaptureKit.
///
/// Audio-only: a 2×2, 1 fps video configuration satisfies the API; video
/// frames are never attached or stored. Matches Recmeet / mac-audio-recorder.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onFailure: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.lectern.capture.system-audio")
    private var stream: SCStream?

    static var expectedFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let excluded = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Int(Self.channelCount)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        let stream = self.stream
        self.stream = nil
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let buffer = AVAudioPCMBuffer.fromSampleBuffer(sampleBuffer) else { return }
        onBuffer?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error)
    }
}
