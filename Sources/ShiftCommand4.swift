// While the app runs, it answers ⇧⌘4 itself, so ⇧⌘4 does what a 🌐 tap does. macOS's own "Save picture of
// selected area as a file" shortcut is switched off for this login session only (no setting is changed) and
// switched back on when the app quits.

import Carbon.HIToolbox
import Foundation

@MainActor
enum ShiftCommand4 {
    private static let systemShortcut: Int32 = 30  // symbolic hotkey: Save picture of selected area as a file
    private static var hotKey: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    // Private SkyLight calls, looked up at run time: on a macOS without them, ⇧⌘4 is simply left alone.
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private static let setEnabled = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: SetEnabled.self) }
    private static let isEnabled = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSIsSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: IsEnabled.self) }

    static var isTakenOver: Bool { hotKey != nil }

    /// Returns whether ⇧⌘4 now runs `action`.
    @discardableResult
    static func takeOver(_ action: @escaping () -> Void) -> Bool {
        guard hotKey == nil else { return true }
        guard let setEnabled, let isEnabled else { return false }
        _ = setEnabled(systemShortcut, false)
        guard !isEnabled(systemShortcut) else { return false }
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { ShiftCommand4.action?() }
            return noErr
        }, 1, &pressed, nil, &handler)
        let id = EventHotKeyID(signature: 0x474C_4F42, id: 4)  // "GLOB"
        guard RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            giveBack()
            return false
        }
        return true
    }

    /// Hands ⇧⌘4 back to macOS, as it's set in Keyboard settings.
    static func giveBack() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
        if isOnInSettings { _ = setEnabled?(systemShortcut, true) }
    }

    /// On unless it's turned off under Keyboard Shortcuts > Screenshots.
    private static var isOnInSettings: Bool {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return ((hotKeys?[String(systemShortcut)] as? [String: Any])?["enabled"] as? Bool) ?? true
    }
}
