// After you open a screenshot from the card, the clipboard follows your edits: each time the editor (Preview) saves
// the file, the new image goes on the clipboard, as long as the clipboard still holds this screenshot. Anything you
// copy in between is left alone. Preview saves through file coordination, so a file presenter hears every save.

import AppKit
import ImageIO
import os

private let log = Logger(subsystem: "com.miguel.globe-screenshot", category: "edits")

final class EditWatcher: NSObject, NSFilePresenter {
    @MainActor private static var current: EditWatcher?

    /// Follows `file`. `changeCount` is the clipboard's change count while it holds this screenshot.
    @MainActor static func follow(_ file: URL, changeCount: Int, pasteboard: NSPasteboard = .general) {
        stop()
        let watcher = EditWatcher(file: file, changeCount: changeCount, pasteboard: pasteboard)
        NSFileCoordinator.addFilePresenter(watcher)
        current = watcher
    }

    @MainActor static func stop() {
        if let current { NSFileCoordinator.removeFilePresenter(current) }
        current = nil
    }

    private(set) var presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    @MainActor private var changeCount: Int
    private let pasteboard: NSPasteboard

    @MainActor private init(file: URL, changeCount: Int, pasteboard: NSPasteboard) {
        presentedItemURL = file
        self.changeCount = changeCount
        self.pasteboard = pasteboard
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func presentedItemDidChange() {
        guard let url = presentedItemURL else { return }
        var image: Data?
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, error: nil) { image = try? Data(contentsOf: $0) }
        guard let image, let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) > 0 else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.copy(image, from: url) }
        }
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
    }

    // No accommodatePresentedItemDeletion: saves that replace the file (Preview's included) announce a deletion right
    // before the change, so treating it as the end would miss the edit.

    @MainActor private func copy(_ image: Data, from file: URL) {
        guard Self.current === self else { return }
        guard pasteboard.changeCount == changeCount else {
            Self.stop()  // something else was copied since; leave it
            return
        }
        pasteboard.clearContents()
        pasteboard.setData(image, forType: .png)
        changeCount = pasteboard.changeCount
        log.notice("copied the edited \(file.lastPathComponent, privacy: .public)")
    }
}
