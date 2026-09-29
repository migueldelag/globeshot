// Globe Screenshot: tap the 🌐 (fn) key on its own to take an area screenshot that lands on the clipboard and in the
// usual file at the same moment. Menu bar only. The key is read straight from the keyboard over IOHID, because macOS
// sends no key event for 🌐 when "Press 🌐 key to" is set to Do Nothing. The capture itself is the system's: the app
// posts ⌃⇧⌘4 (area to clipboard), then saves that image as the file ⇧⌘4 would have written.

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
    private var captureEnd: DispatchSourceProcess?

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
        // The Desktop is privacy-protected: ask for access now rather than in the middle of a capture.
        let folder = ScreenshotFile.folder.path
        DispatchQueue.global(qos: .utility).async { _ = try? FileManager.default.contentsOfDirectory(atPath: folder) }
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

    /// Posts ⌃⇧⌘4, the system shortcut for "Copy picture of selected area to the clipboard", so the image is on the
    /// clipboard the moment the selection ends, then saves the same image as the usual file.
    private func takeAreaScreenshot() {
        refreshIcon()
        guard AXIsProcessTrusted() else {
            log.error("⌃⇧⌘4 not sent: Accessibility access is off")
            return
        }
        let earlierCaptures = processIDs(named: "screencapture")
        let changeCount = NSPasteboard.general.changeCount
        press(kVK_ANSI_4, holding: [(kVK_Control, .maskControl), (kVK_Shift, .maskShift), (kVK_Command, .maskCommand)])
        saveWhenCaptureEnds(changeCount: changeCount, ignoring: earlierCaptures)
    }

    /// Holds the modifiers down in order, taps the key, then lets go, the way fingers would.
    private func press(_ key: Int, holding modifiers: [(key: Int, flag: CGEventFlags)]) {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0  // don't hold back the mouse while you start dragging
        var flags: CGEventFlags = []
        func post(_ key: Int, _ isDown: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: isDown)
            event?.flags.formUnion(flags)  // keeps the left-key and non-coalesced bits CoreGraphics sets
            event?.post(tap: .cghidEventTap)
        }
        for modifier in modifiers {
            flags.insert(modifier.flag)
            post(modifier.key, true)
        }
        post(key, true)
        post(key, false)
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            post(modifier.key, false)
        }
    }

    // MARK: Screenshot file

    /// The system runs a `screencapture` process while the crosshair is up. Once it exits, the image is on the
    /// clipboard, unless the capture was cancelled.
    private func saveWhenCaptureEnds(changeCount: Int, ignoring earlier: Set<pid_t>, triesLeft: Int = 60) {
        guard let pid = processIDs(named: "screencapture").subtracting(earlier).first else {
            if triesLeft == 0 {
                log.error("the screenshot tool didn't start, so no file was saved")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.saveWhenCaptureEnds(changeCount: changeCount, ignoring: earlier, triesLeft: triesLeft - 1) }
            }
            return
        }
        captureEnd?.cancel()
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in
            exit.cancel()
            MainActor.assumeIsolated { self?.saveClipboardImage(changedSince: changeCount) }
        }
        exit.resume()
        captureEnd = exit
        if kill(pid, 0) != 0 {  // it ended before the watch was in place
            exit.cancel()
            saveClipboardImage(changedSince: changeCount)
        }
    }

    /// Saves the capture from the clipboard as the file ⇧⌘4 would have written.
    private func saveClipboardImage(changedSince changeCount: Int, checksLeft: Int = 20) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else {
            // Cancelled, or the clipboard is written a moment after the process ends: check again for up to a second.
            guard checksLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.saveClipboardImage(changedSince: changeCount, checksLeft: checksLeft - 1) }
            }
            return
        }
        guard let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return }
        let pointer = NSEvent.mouseLocation  // the selection ends on the display under the pointer
        let scale = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }?.backingScaleFactor ?? 2
        let file = ScreenshotFile.url(for: Date(), in: ScreenshotFile.folder)
        DispatchQueue.global(qos: .utility).async {
            do {
                try ScreenshotFile.save(image, dpi: 72 * scale, to: file)
                log.notice("saved \(file.lastPathComponent, privacy: .public)")
            } catch {
                log.error("couldn't save the screenshot: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// PIDs of running processes with this name. `screencapture` is a plain binary, so NSWorkspace doesn't list it.
    private func processIDs(named name: String) -> Set<pid_t> {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return Set(pids.prefix(max(count, 0)).filter { pid in
            var buffer = [CChar](repeating: 0, count: 256)
            return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == name
        })
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
