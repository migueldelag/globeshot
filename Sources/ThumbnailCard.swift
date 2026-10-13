// A stand-in for macOS's floating screenshot thumbnail, which macOS only shows for captures it saves to a file
// itself. It fades in at the bottom right of the screen the capture was taken on, stays 5 seconds (as long as you like
// while the pointer is on it), then slides away. Click to open in Preview (the clipboard then follows your edits), drag
// it into another app, swipe it off, or right-click for Show in Finder and Delete.

import AppKit
import ImageIO

@MainActor
final class ThumbnailCard: NSObject, NSDraggingSource {
    private static var current: ThumbnailCard?
    // Measured from macOS's own card: the image (square corners, at most 150 pt) in a ½ pt white line and a 4 pt black
    // frame with 5 pt outer corners, a tight rim shadow, 12 pt from the right and bottom edges of the screen.
    private static let maxImageSide: CGFloat = 150
    private static let minImageSide: CGFloat = 24
    fileprivate static let frameWidth: CGFloat = 4
    fileprivate static let lineWidth: CGFloat = 0.5
    fileprivate static let cornerRadius: CGFloat = 5
    fileprivate static let shadowRoom: CGFloat = 4  // transparent room around the card for its rim shadow
    private static let margin: CGFloat = 12
    private static let stay: TimeInterval = 5

    /// Shows the card for a saved capture, replacing any card already up. `size` is the capture's size in points;
    /// `clipboardChangeCount` is the clipboard's change count while it holds this capture.
    static func show(_ thumbnail: CGImage, size: NSSize, file: URL, clipboardChangeCount: Int, screenFrame: NSRect, visibleFrame: NSRect) {
        current?.close(animated: false)
        let card = ThumbnailCard(thumbnail, size: size, file: file, clipboardChangeCount: clipboardChangeCount,
                                 screenFrame: screenFrame, visibleFrame: visibleFrame)
        current = card
        card.fadeIn()
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
    private let clipboardChangeCount: Int
    private let panel: NSPanel
    private let shownFrame: NSRect
    private let hiddenFrame: NSRect
    private var timer: Timer?
    private var isClosing = false

    private init(_ thumbnail: CGImage, size: NSSize, file: URL, clipboardChangeCount: Int, screenFrame: NSRect, visibleFrame: NSRect) {
        self.thumbnail = thumbnail
        self.file = file
        self.clipboardChangeCount = clipboardChangeCount
        let scale = min(Self.maxImageSide / size.width, Self.maxImageSide / size.height, 1)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        let isThinStrip = min(fitted.width, fitted.height) < Self.minImageSide
        let border = Self.frameWidth + Self.lineWidth
        let cardSize = NSSize(width: max(fitted.width, Self.minImageSide) + 2 * border,
                              height: max(fitted.height, Self.minImageSide) + 2 * border)
        let card = NSRect(x: visibleFrame.maxX - Self.margin - cardSize.width, y: visibleFrame.minY + Self.margin,
                          width: cardSize.width, height: cardSize.height)
        shownFrame = card.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom)
        hiddenFrame = shownFrame.offsetBy(dx: screenFrame.maxX + Self.shadowRoom - card.minX, dy: 0)  // just past the right edge
        panel = NSPanel(contentRect: shownFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the card draws macOS's rim shadow itself; a window shadow is much heavier
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none  // keep the card out of screenshots and recordings
        panel.contentView = CardView(thumbnail, letterboxed: isThinStrip, card: self)
    }

    private func fadeIn() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
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
        EditWatcher.follow(file, changeCount: clipboardChangeCount)  // edits saved in Preview go to the clipboard too
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
        let card = view.bounds.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
        item.setDraggingFrame(card, contents: NSImage(cgImage: thumbnail, size: card.size))
        view.beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty { restartTimer() } else { close(animated: false) }
    }
}

/// The card's face, built like macOS's: the capture with square corners, a ½ pt white line around it, a black frame
/// with rounded outer corners, and a rim shadow. Thin strips are letterboxed.
private final class CardView: NSView {
    private weak var card: ThumbnailCard?
    private let frameLayer = CALayer()
    private let imageLayer = CALayer()
    private let lineLayer = CALayer()
    private var pressedAt: NSPoint?
    private var swipe: CGFloat = 0

    init(_ thumbnail: CGImage, letterboxed: Bool, card: ThumbnailCard) {
        self.card = card
        super.init(frame: .zero)
        wantsLayer = true
        frameLayer.cornerRadius = ThumbnailCard.cornerRadius
        frameLayer.backgroundColor = .black
        frameLayer.shadowColor = .black
        frameLayer.shadowOpacity = 0.34  // about 16% at the frame's edge, gone 2 pt out, as measured
        frameLayer.shadowRadius = 2.2
        frameLayer.shadowOffset = .zero
        imageLayer.contents = thumbnail
        imageLayer.contentsGravity = letterboxed ? .resizeAspect : .resize  // .resize: no sub-pixel gap at the edges
        lineLayer.borderWidth = ThumbnailCard.lineWidth
        lineLayer.borderColor = .white
        layer?.addSublayer(frameLayer)
        frameLayer.addSublayer(imageLayer)
        frameLayer.addSublayer(lineLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }  // nothing to draw; the layers carry the card

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds.insetBy(dx: ThumbnailCard.shadowRoom, dy: ThumbnailCard.shadowRoom)
        frameLayer.shadowPath = CGPath(roundedRect: frameLayer.bounds, cornerWidth: ThumbnailCard.cornerRadius,
                                       cornerHeight: ThumbnailCard.cornerRadius, transform: nil)
        let image = frameLayer.bounds.insetBy(dx: ThumbnailCard.frameWidth + ThumbnailCard.lineWidth,
                                              dy: ThumbnailCard.frameWidth + ThumbnailCard.lineWidth)
        imageLayer.frame = image
        lineLayer.frame = image.insetBy(dx: -ThumbnailCard.lineWidth, dy: -ThumbnailCard.lineWidth)
        CATransaction.commit()
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
