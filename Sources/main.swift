// Globe Screenshot: tap the 🌐 (fn) key on its own for macOS's own area screenshot (⇧⌘4, with its floating card),
// and the image also goes on the clipboard once macOS saves the file. Menu bar only. The key is read straight from
// the keyboard over IOHID, because macOS sends no key event for 🌐 when "Press 🌐︎ key to" is set to Do Nothing.

import AppKit
import Carbon.HIToolbox
import IOKit.hid
import ServiceManagement
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.miguel.globe-screenshot", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var keyboards: IOHIDManager?
    private var globeIsDown = false
    private var pressedAt: TimeInterval?  // nil while the current press can't be a tap
    private var screenshotWatch: DispatchSourceFileSystemObject?

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
        let folder = screenshotFolder.path
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

    /// Posts ⇧⌘4, the system shortcut for "Save picture of selected area as a file", then copies that file.
    private func takeAreaScreenshot() {
        refreshIcon()
        guard AXIsProcessTrusted() else {
            log.error("⇧⌘4 not sent: Accessibility access is off")
            return
        }
        copyScreenshotToClipboard(savedAfter: Date())
        press(kVK_ANSI_4, holding: [(kVK_Command, .maskCommand), (kVK_Shift, .maskShift)])
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

    // MARK: Clipboard copy

    /// Where ⇧⌘4 saves: the screenshot "location" setting, the Desktop by default.
    private var screenshotFolder: URL {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        if let path = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Watches the screenshot folder until this capture's file lands, then puts the image on the clipboard.
    /// With the floating thumbnail on, macOS saves the file only once the thumbnail goes away.
    private func copyScreenshotToClipboard(savedAfter start: Date) {
        screenshotWatch?.cancel()
        let folder = screenshotFolder
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("can't watch \(folder.path, privacy: .public) for the screenshot")
            return
        }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.copyNewScreenshot(in: folder, savedAfter: start, watch: watch, retries: 5) }
        }
        watch.setCancelHandler { close(fd) }
        watch.resume()
        screenshotWatch = watch
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { watch.cancel() }  // a cancelled capture saves nothing
    }

    private func copyNewScreenshot(in folder: URL, savedAfter start: Date, watch: DispatchSourceFileSystemObject, retries: Int) {
        guard !watch.isCancelled else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        let saved = files
            .compactMap { file in (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate).map { (file, $0) } }
            .filter { $0.1 >= start }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        guard !saved.isEmpty else { return }
        for file in saved where isScreenCapture(file) {
            guard let data = finishedImageData(file), let type = UTType(filenameExtension: file.pathExtension) else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            watch.cancel()
            log.notice("copied \(file.lastPathComponent, privacy: .public) to the clipboard")
            return
        }
        // A new file that isn't finished or tagged yet: look again shortly.
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.copyNewScreenshot(in: folder, savedAfter: start, watch: watch, retries: retries - 1) }
        }
    }

    /// macOS tags every screenshot it saves with this Spotlight attribute.
    private func isScreenCapture(_ file: URL) -> Bool {
        getxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// The file's bytes once it's completely written. A finished PNG ends with its IEND chunk.
    private func finishedImageData(_ file: URL) -> Data? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        let pngEnd = Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        return file.pathExtension.lowercased() != "png" || data.suffix(8) == pngEnd ? data : nil
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
            menu.addItem(item("Set “Press 🌐︎ key to” to Do Nothing…", #selector(openKeyboardSettings)))
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

    /// False when Keyboard settings has "Press 🌐︎ key to" on Do Nothing (0), or Modifier Keys has the 🌐︎ key on
    /// No Action. Otherwise every tap also opens the emoji picker, switches input source or starts dictation.
    private var globeKeyHasSystemAction: Bool {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        let usage = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        return usage != 0 && !globeKeyIsOff
    }

    /// Modifier Keys keeps "Globe key: No Action" per keyboard, mapping fn (0xFF01/0x03 or 0xFF/0x03) to no key (0x07/0x00).
    private var globeKeyIsOff: Bool {
        let (app, user, host) = (kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(app, user, host)
        let keys = CFPreferencesCopyKeyList(app, user, host) as? [String] ?? []
        return keys.filter { $0.hasPrefix("com.apple.keyboard.modifiermapping") }.contains { key in
            let pairs = CFPreferencesCopyValue(key as CFString, app, user, host) as? [[String: Int]] ?? []
            return pairs.contains { [0xFF01_0000_0003, 0xFF_0000_0003].contains($0["HIDKeyboardModifierMappingSrc"]) && $0["HIDKeyboardModifierMappingDst"] == 0x7_0000_0000 }
        }
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
