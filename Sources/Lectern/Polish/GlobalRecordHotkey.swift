import AppKit
import Carbon.HIToolbox
import Foundation

/// Permissionless global record hotkey: start/stop recording from anywhere.
/// Key + modifiers are user-configurable (Settings › General); defaults to
/// ⌥⌘R so it never collides with ⌘R-reload in browsers.
enum GlobalRecordHotkey {
    private final class CallbackBox: @unchecked Sendable {
        let onToggle: () -> Void
        let onBookmark: () -> Void
        init(onToggle: @escaping () -> Void, onBookmark: @escaping () -> Void) {
            self.onToggle = onToggle
            self.onBookmark = onBookmark
        }
    }

    static let defaultKeyCode = Int(kVK_ANSI_R)
    static let defaultModifiers = Int(cmdKey | optionKey)

    // Installed once at app init on the main actor; Carbon handles are raw
    // pointers, so confinement to @MainActor is the safety story.
    private nonisolated(unsafe) static var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) static var bookmarkHotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) static var eventHandler: EventHandlerRef?
    private nonisolated(unsafe) static var callbackBox: CallbackBox?
    private nonisolated(unsafe) static var installedKeyCode: Int = -1
    private nonisolated(unsafe) static var installedModifiers: Int = -1

    static var storedKeyCode: Int {
        UserDefaults.standard.object(forKey: "hotkey.keycode") as? Int ?? defaultKeyCode
    }

    static var storedModifiers: Int {
        UserDefaults.standard.object(forKey: "hotkey.modifiers") as? Int ?? defaultModifiers
    }

    /// Install must be called once at app startup.
    static func install(onToggle: @escaping () -> Void,
                        onBookmark: @escaping () -> Void = {}) {
        callbackBox = CallbackBox(onToggle: onToggle, onBookmark: onBookmark)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let boxPointer = Unmanaged.passRetained(callbackBox!).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                DispatchQueue.main.async {
                    if hotKeyID.id == 2 {
                        box.onBookmark()
                    } else {
                        box.onToggle()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            boxPointer,
            &eventHandler
        )

        register(storedKeyCode, storedModifiers)
        registerBookmark()
    }

    /// Re-register with the currently stored combination (after a Settings change).
    static func reinstall() {
        guard eventHandler != nil else { return }
        let keyCode = storedKeyCode
        let modifiers = storedModifiers
        guard keyCode != installedKeyCode || modifiers != installedModifiers else { return }
        register(keyCode, modifiers)
    }

    private static func register(_ keyCode: Int, _ modifiers: Int) {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
        }
        hotKeyRef = nil
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C_45_52_4E), // "LERN"
                                     id: 1)
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        installedKeyCode = keyCode
        installedModifiers = modifiers
    }

    private static func registerBookmark() {
        if let existing = bookmarkHotKeyRef {
            UnregisterEventHotKey(existing)
        }
        bookmarkHotKeyRef = nil
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C_45_52_4E), id: 2)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &bookmarkHotKeyRef
        )
    }

    // MARK: - Display

    /// Human-readable label for the stored combination, e.g. "⌥⌘R".
    static var storedDisplayLabel: String {
        displayLabel(keyCode: storedKeyCode, modifiers: storedModifiers)
    }

    static func displayLabel(keyCode: Int, modifiers: Int) -> String {
        var label = ""
        if modifiers & Int(controlKey) != 0 { label += "⌃" }
        if modifiers & Int(optionKey) != 0 { label += "⌥" }
        if modifiers & Int(shiftKey) != 0 { label += "⇧" }
        if modifiers & Int(cmdKey) != 0 { label += "⌘" }
        label += Self.keyLabel(keyCode)
        return label
    }

    /// Keys whose display name isn't produced by the keyboard layout (letters,
    /// digits and punctuation go through UCKeyTranslate instead).
    private static let namedKeys: [Int: String] = [
        Int(kVK_Space): "Space",
        Int(kVK_Return): "↩",
        Int(kVK_Tab): "⇥",
        Int(kVK_Delete): "⌫",
        Int(kVK_Escape): "⎋",
        Int(kVK_LeftArrow): "←",
        Int(kVK_RightArrow): "→",
        Int(kVK_DownArrow): "↓",
        Int(kVK_UpArrow): "↑",
        Int(kVK_F1): "F1",
        Int(kVK_F2): "F2",
        Int(kVK_F3): "F3",
        Int(kVK_F4): "F4",
        Int(kVK_F5): "F5",
        Int(kVK_F6): "F6",
        Int(kVK_F7): "F7",
        Int(kVK_F8): "F8",
        Int(kVK_F9): "F9",
        Int(kVK_F10): "F10",
        Int(kVK_F11): "F11",
        Int(kVK_F12): "F12",
        Int(kVK_F13): "F13",
        Int(kVK_F14): "F14",
        Int(kVK_F15): "F15",
        Int(kVK_F16): "F16",
        Int(kVK_F17): "F17",
        Int(kVK_F18): "F18",
        Int(kVK_F19): "F19",
        Int(kVK_F20): "F20",
    ]

    /// True function keys (scan codes are not contiguous; never range-check them).
    static let functionKeyCodes: Set<Int> = [
        Int(kVK_F1), Int(kVK_F2), Int(kVK_F3), Int(kVK_F4), Int(kVK_F5),
        Int(kVK_F6), Int(kVK_F7), Int(kVK_F8), Int(kVK_F9), Int(kVK_F10),
        Int(kVK_F11), Int(kVK_F12), Int(kVK_F13), Int(kVK_F14), Int(kVK_F15),
        Int(kVK_F16), Int(kVK_F17), Int(kVK_F18), Int(kVK_F19), Int(kVK_F20),
    ]

    private static func keyLabel(_ keyCode: Int) -> String {
        if let named = namedKeys[keyCode] { return named }
        var chars: UniChar = 0
        var length: Int = 0
        var state: UInt32 = 0
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
        let result = data.withUnsafeBytes { buffer -> OSStatus in
            UCKeyTranslate(buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress,
                           UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay),
                           0,
                           UInt32(LMGetKbdType()),
                           UInt32(kUCKeyTranslateNoDeadKeysMask),
                           &state,
                           1,
                           &length,
                           &chars)
        }
        if result == noErr, length > 0, let scalar = Unicode.Scalar(chars) {
            return String(Character(scalar)).uppercased()
        }
        return "?"
    }

    /// Carbon modifier flags from an NSEvent modifier set (order-stable subset).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= Int(cmdKey) }
        if flags.contains(.option) { carbon |= Int(optionKey) }
        if flags.contains(.shift) { carbon |= Int(shiftKey) }
        if flags.contains(.control) { carbon |= Int(controlKey) }
        return carbon
    }
}
