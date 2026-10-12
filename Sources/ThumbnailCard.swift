// A stand-in for macOS's floating screenshot thumbnail, which macOS only shows for captures it saves to a file
// itself. It slides in at the bottom right of the screen the capture was taken on, stays 5 seconds (as long as you
// like while the pointer is on it), then slides away. Click to open in Preview, drag it into another app, swipe it
// off, or right-click for Show in Finder and Delete.

import AppKit
import ImageIO

@MainActor
final class ThumbnailCard: NSObject, NSDraggingSource {
    private static var current: ThumbnailCard?
    private static let maxSize = NSSize(width: 200, height: 150)
    private static let minSide: CGFloat = 40
    private static let margin: CGFloat = 20
    private static let stay: TimeInterval = 5

    /// Shows the card for a saved capture, replacing any card already up. `size` is the capture's size in points.
    static func show(_ thumbnail: CGImage, size: NSSize, file: URL, screenFrame: NSRect, visibleFrame: NSRect) {
        current?.close(animated: false)
        let card = ThumbnailCard(thumbnail, size: size, file: file, screenFrame: screenFrame, visibleFrame: visibleFrame)
        current = card
        card.slideIn()
    }

    /// Takes the card down at once, so it doesn't end up in the next capture.
    static func hide() {
        current?.close(animated: false)
    }

    /// A downscaled copy of the capture for the card (the full image can be thousands of pixels wide), with the
    /// full image's size in pixels.
    nonisolated static func thumbnail(of image: Data) -> (image: CGImage, pixels: CGSize)? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return (thumbnail, CGSize(width: width, height: height))
    }

    private let thumbnail: CGImage
    private let file: URL
    private let panel: NSPanel
    private let shownFrame: NSRect
    private let hiddenFrame: NSRect
    private var timer: Timer?
    private var isClosing = false

    private init(_ thumbnail: CGImage, size: NSSize, file: URL, screenFrame: NSRect, visibleFrame: NSRect) {
        self.thumbnail = thumbnail
        self.file = file
        let scale = min(Self.maxSize.width / size.width, Self.maxSize.height / size.height, 1)
        let cardSize = NSSize(width: max(size.width * scale, Self.minSide), height: max(size.height * scale, Self.minSide))
        shownFrame = NSRect(x: visibleFrame.maxX - Self.margin - cardSize.width, y: visibleFrame.minY + Self.margin,
                            width: cardSize.width, height: cardSize.height)
        hiddenFrame = shownFrame.offsetBy(dx: screenFrame.maxX + Self.margin - shownFrame.minX, dy: 0)  // just past the right edge
        panel = NSPanel(contentRect: hiddenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none  // keep the card out of screenshots and recordings
        panel.contentView = CardView(thumbnail, card: self)
    }

    private func slideIn() {
        panel.setFrame(hiddenFrame, display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(shownFrame, display: true)
        }
        restartTimer()
    }

    fileprivate func close(animated: Bool) {
        guard !isClosing else { return }
        isClosing = true
        timer?.invalidate()
        if Self.current === self { Self.current = nil }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: true)
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }

    fileprivate func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.stay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: true) }
        }
    }

    fileprivate func pauseTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Actions

    @objc fileprivate func open() {
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([file], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
        close(animated: false)
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([file])
        close(animated: false)
    }

    @objc private func moveToTrash() {
        NSWorkspace.shared.recycle([file])
        close(animated: true)
    }

    @objc private func dismiss() {
        close(animated: true)
    }

    fileprivate func showMenu(for event: NSEvent, in view: NSView) {
        pauseTimer()
        let menu = NSMenu()
        for (title, action) in [("Open in Preview", #selector(open)), ("Show in Finder", #selector(showInFinder)),
                                ("Delete", #selector(moveToTrash)), ("Close", #selector(dismiss))] {
            if title == "Delete" { menu.addItem(.separator()) }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)  // returns once the menu closes
        if !isClosing { restartTimer() }
    }

    // MARK: Dragging into other apps

    fileprivate func beginDrag(with event: NSEvent, from view: NSView) {
        pauseTimer()
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(view.bounds, contents: NSImage(cgImage: thumbnail, size: view.bounds.size))
        view.beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty { restartTimer() } else { close(animated: false) }
    }
}

/// The card's face: the capture with rounded corners and a hairline edge, letterboxed when it's a thin strip.
private final class CardView: NSView {
    private let thumbnail: CGImage
    private weak var card: ThumbnailCard?
    private var pressedAt: NSPoint?
    private var swipe: CGFloat = 0

    init(_ thumbnail: CGImage, card: ThumbnailCard) {
        self.thumbnail = thumbnail
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = thumbnail
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = NSColor.separatorColor.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { card?.pauseTimer() }
    override func mouseExited(with event: NSEvent) { card?.restartTimer() }
    override func mouseDown(with event: NSEvent) { pressedAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        pressedAt = nil
        card?.beginDrag(with: event, from: self)
    }

    override func mouseUp(with event: NSEvent) {
        if pressedAt != nil { card?.open() }
        pressedAt = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        card?.showMenu(for: event, in: self)
    }

    /// A sideways two-finger swipe sends the card away.
    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { swipe = 0 }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        swipe += event.scrollingDeltaX
        if abs(swipe) > 40 {
            swipe = 0
            card?.close(animated: true)
        }
    }
}
