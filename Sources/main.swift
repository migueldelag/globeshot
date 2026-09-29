// Globe Screenshot: tap the 🌐 (fn) key on its own to take an area screenshot, same as ⇧⌘4.
// Menu bar only. The key is read straight from the keyboard over IOHID, because macOS sends no key event
// for 🌐 when "Press 🌐 key to" is set to Do Nothing. The capture itself is the system's: the app posts ⇧⌘4,
// so your screenshot settings (save location, floating thumbnail, hold ⌃ for clipboard) all apply.

import AppKit
import Carbon.HIToolbox
import IOKit.hid
import ServiceManagement
import os

private let log = Logger(subsystem: "com.miguel.globe-screenshot", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var keyboards: IOHIDManager?
    private var globeIsDown = false
    private var pressedAt: TimeInterval?  // nil while the current press can't be a tap

    /// Held longer than this, 🌐 counts as a modifier rather than a tap.
    private let maxTap: TimeInterval = 0.5
    private let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Globe Screenshot")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerLoginItemOnFirstLaunch()
        listenToGlobeKey()
        // One prompt at a time: Input Monitoring first (macOS relaunches the app after it), then Accessibility.
        if keyboards != nil && !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        refreshIcon()
    }

    // MARK: 🌐 key

    private func listenToGlobeKey() {
        guard keyboards == nil else { return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)  // shows the system prompt the first time
            log.notice("waiting for Input Monitoring access")
            return
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        // 🌐 is the Apple vendor top case page (0xFF), KeyboardFn usage (0x03), on the built-in and Magic keyboards.
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: 0xFF, kIOHIDElementUsageKey: 0x03] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            let isDown = IOHIDValueGetIntegerValue(value) != 0
            MainActor.assumeIsolated {
                Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue().globeKey(isDown: isDown)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            log.error("could not open keyboards: \(String(format: "0x%x", result), privacy: .public)")
            return
        }
        keyboards = manager
        log.notice("listening to 🌐 on \((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0) keyboards")
    }

    /// A lone tap is short, with no other modifier held and no key pressed while 🌐 was down (🌐←, 🌐⌫, 🌐F…).
    private func globeKey(isDown: Bool) {
        guard isDown != globeIsDown else { return }  // a repeated report for the same state
        globeIsDown = isDown
        let now = ProcessInfo.processInfo.systemUptime
        let modifiersHeld = !CGEventSource.flagsState(.hidSystemState).intersection(otherModifiers).isEmpty
        if isDown {
            pressedAt = modifiersHeld ? nil : now
            return
        }
        guard let start = pressedAt else { return }
        pressedAt = nil
        let held = now - start
        let keyPressedMeanwhile = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < held
        let isTap = held <= maxTap && !modifiersHeld && !keyPressedMeanwhile
        log.notice("🌐 up after \(Int(held * 1000)) ms, key meanwhile: \(keyPressedMeanwhile), modifier: \(modifiersHeld) -> \(isTap ? "screenshot" : "ignored", privacy: .public)")
        if isTap { takeAreaScreenshot() }
    }

    /// Posts ⇧⌘4, the system shortcut for "Save picture of selected area as a file".
    private func takeAreaScreenshot() {
        refreshIcon()
        guard AXIsProcessTrusted() else {
            log.error("⇧⌘4 not sent: Accessibility access is off")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0  // don't hold back the mouse while you start dragging
        let commandShift: CGEventFlags = [.maskCommand, .maskShift]
        let keys: [(CGKeyCode, Bool, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), true, .maskCommand),
            (CGKeyCode(kVK_Shift), true, commandShift),
            (CGKeyCode(kVK_ANSI_4), true, commandShift),
            (CGKeyCode(kVK_ANSI_4), false, commandShift),
            (CGKeyCode(kVK_Shift), false, .maskCommand),
            (CGKeyCode(kVK_Command), false, []),
        ]
        for (key, isDown, flags) in keys {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags.formUnion(flags)  // keeps the left-key and non-coalesced bits CoreGraphics sets
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        listenToGlobeKey()  // picks up an Input Monitoring grant made while running
        menu.removeAllItems()
        if keyboards == nil {
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
                menu.addItem(item("Reopen to Finish Setup", #selector(relaunch)))
            } else {
                menu.addItem(item("Allow Input Monitoring…", #selector(openInputMonitoringSettings)))
            }
        }
        if !AXIsProcessTrusted() {
            menu.addItem(item("Allow Accessibility…", #selector(openAccessibilitySettings)))
        }
        if globeKeyHasSystemAction {
            menu.addItem(item("Set “Press 🌐 key to” to Do Nothing…", #selector(openKeyboardSettings)))
        }
        if menu.items.isEmpty {
            menu.addItem(NSMenuItem(title: "Tap 🌐 for an area screenshot", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Globe Screenshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        refreshIcon()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Dimmed until both permissions are in place.
    private func refreshIcon() {
        statusItem.button?.appearsDisabled = keyboards == nil || !AXIsProcessTrusted()
    }

    /// False only when Keyboard settings has "Press 🌐 key to" on Do Nothing (0). Anything else also opens
    /// the emoji picker, switches input source or starts dictation on every tap.
    private var globeKeyHasSystemAction: Bool {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        return (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int) != 0
    }

    @objc private func openInputMonitoringSettings() { openSettings("com.apple.preference.security?Privacy_ListenEvent") }
    @objc private func openAccessibilitySettings() { openSettings("com.apple.preference.security?Privacy_Accessibility") }
    @objc private func openKeyboardSettings() { openSettings("com.apple.Keyboard-Settings.extension") }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
    }

    @objc private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Open at login

    private func registerLoginItemOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "loginItemSetUp") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemSetUp")
        do { try SMAppService.mainApp.register() } catch { log.error("open at login failed: \(error.localizedDescription, privacy: .public)") }
        log.notice("open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off", privacy: .public)")
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            log.error("open at login toggle failed: \(error.localizedDescription, privacy: .public)")
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
