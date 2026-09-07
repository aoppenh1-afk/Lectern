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
    private var zoomAppsOnly = false

    static var expectedFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
    }

    func start() async throws {
        try await start(zoomAppsOnly: false)
    }

    /// Starts capture. With `zoomAppsOnly`, the stream allowlists the running
    /// Zoom desktop processes instead of the full display mix, so sounds from
    /// other apps — a YouTube video opened mid-lecture, notification pings —
    /// are never captured. Throws `CaptureError.zoomAppNotRunning` when Zoom
    /// isn't running.
    func start(zoomAppsOnly: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter: SCContentFilter
        if zoomAppsOnly {
            let targets = MeetingAudioTarget.matchingApplications(content.applications)
            guard !targets.isEmpty else {
                throw CaptureError.zoomAppNotRunning
            }
            filter = SCContentFilter(display: display, including: targets, exceptingWindows: [])
        } else {
            let excluded = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(
                display: display,
                excludingApplications: excluded,
                exceptingWindows: []
            )
        }
        self.zoomAppsOnly = zoomAppsOnly

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
        zoomAppsOnly = false
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    /// Re-resolves the Zoom processes and pushes an updated allowlist to the
    /// running stream — no restart needed. Covers Zoom relaunching mid-lecture
    /// under a new PID. Throws `CaptureError.zoomAppQuit` when no Zoom
    /// process remains. No-op unless the stream runs in Zoom-only mode.
    func refreshZoomApps() async throws {
        guard zoomAppsOnly, let stream else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        let targets = MeetingAudioTarget.matchingApplications(content.applications)
        guard !targets.isEmpty else {
            throw CaptureError.zoomAppQuit
        }
        try await stream.updateContentFilter(
            SCContentFilter(display: display, including: targets, exceptingWindows: [])
        )
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
