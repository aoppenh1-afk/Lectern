import Foundation
import Observation
import SwiftUI

/// Mirrors the recording-surface toggles, theme choices, and record hotkey from
/// Settings, keeping every surface (menu-bar popover, notch pill, main window)
/// in sync, independently.
@MainActor
@Observable
final class SurfacePreferences {
    private(set) var popoverEnabled: Bool
    private(set) var pillEnabled: Bool
    private(set) var appearanceMode: String
    private(set) var accentID: String
    private(set) var hotKeyCode: Int
    private(set) var hotKeyModifiers: Int

    enum AppearanceMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceMode) ?? .system
    }

    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?

    init() {
        popoverEnabled = Self.currentPopoverSetting()
        pillEnabled = Self.currentPillSetting()
        appearanceMode = UserDefaults.standard.string(forKey: "appearance.mode") ?? AppearanceMode.system.rawValue
        accentID = UserDefaults.standard.string(forKey: "appearance.accent") ?? "moss"
        hotKeyCode = UserDefaults.standard.object(forKey: "hotkey.keycode") as? Int ?? GlobalRecordHotkey.defaultKeyCode
        hotKeyModifiers = UserDefaults.standard.object(forKey: "hotkey.modifiers") as? Int ?? GlobalRecordHotkey.defaultModifiers

        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.popoverEnabled = Self.currentPopoverSetting()
                self.pillEnabled = Self.currentPillSetting()
                self.appearanceMode = UserDefaults.standard.string(forKey: "appearance.mode") ?? AppearanceMode.system.rawValue
                self.accentID = UserDefaults.standard.string(forKey: "appearance.accent") ?? "moss"
                self.hotKeyCode = UserDefaults.standard.object(forKey: "hotkey.keycode") as? Int ?? GlobalRecordHotkey.defaultKeyCode
                self.hotKeyModifiers = UserDefaults.standard.object(forKey: "hotkey.modifiers") as? Int ?? GlobalRecordHotkey.defaultModifiers
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setPopoverEnabled(_ enabled: Bool) {
        popoverEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "surface.popoverEnabled")
    }

    private nonisolated static func currentPopoverSetting() -> Bool {
        UserDefaults.standard.object(forKey: "surface.popoverEnabled") as? Bool ?? true
    }

    private nonisolated static func currentPillSetting() -> Bool {
        UserDefaults.standard.object(forKey: "surface.pillEnabled") as? Bool ?? false
    }
}
