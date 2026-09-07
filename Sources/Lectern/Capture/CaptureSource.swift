import Foundation

/// Where a live lecture recording listens.
///
/// In-person classes use the microphone. Zoom, Meet, and any other playback
/// on this Mac use system audio via ScreenCaptureKit — the same approach as
/// Recmeet and mac-audio-recorder, with no virtual audio driver. The Zoom-app
/// variant allowlists only the Zoom desktop processes, so other Mac sounds
/// (a YouTube video, notification pings) are left out.
enum CaptureSource: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio
    case zoomApp
    case mixed

    var id: String { rawValue }

    static let defaultsKey = "capture.source"

    static var preferred: CaptureSource {
        CaptureSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            ?? .microphone
    }

    static func persist(_ source: CaptureSource) {
        UserDefaults.standard.set(source.rawValue, forKey: defaultsKey)
    }

    var includesMicrophone: Bool { self == .microphone || self == .mixed }
    var includesSystemAudio: Bool { self != .microphone }

    /// True for the allowlist mode that captures only the Zoom desktop app,
    /// leaving out everything else on this Mac.
    var zoomAppOnly: Bool { self == .zoomApp }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .systemAudio: return "Zoom / system audio"
        case .zoomApp: return "Zoom app only"
        case .mixed: return "Zoom + microphone"
        }
    }

    var shortTitle: String {
        switch self {
        case .microphone: return "Mic"
        case .systemAudio: return "Zoom"
        case .zoomApp: return "Zoom app"
        case .mixed: return "Zoom + mic"
        }
    }

    var recordButtonTitle: String {
        switch self {
        case .microphone: return "Record"
        case .systemAudio: return "Record Zoom"
        case .zoomApp: return "Record Zoom app"
        case .mixed: return "Record Zoom + Mic"
        }
    }

    var caption: String {
        switch self {
        case .microphone:
            return "The built-in or external mic. Use this in the room."
        case .systemAudio:
            return "Whatever this Mac is playing — Zoom, Meet, or a lecture video. No video is stored."
        case .zoomApp:
            return "Only the Zoom desktop app. Other Mac sounds — a YouTube video, pings — are left out. Zoom must be running when you start."
        case .mixed:
            return "System audio plus your microphone, so questions you ask on Zoom are kept too."
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "laptopcomputer"
        case .zoomApp: return "video.fill"
        case .mixed: return "mic.and.signal.meter.fill"
        }
    }
}
