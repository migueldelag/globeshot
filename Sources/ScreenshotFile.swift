// The file half of a Globe screenshot. ⌃⇧⌘4 puts the capture on the clipboard; this saves the same image the way
// ⇧⌘4 would have: same folder, same name, 144 DPI on Retina, tagged as a screenshot, extension hidden.

import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotFile {
    private static let domain = "com.apple.screencapture" as CFString

    /// Where ⇧⌘4 saves: the screenshot "location" setting, the Desktop by default.
    static var folder: URL {
        CFPreferencesAppSynchronize(domain)
        if let path = CFPreferencesCopyAppValue("location" as CFString, domain) as? String {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The system's name for a capture taken at `date`, like "Screenshot 2026-09-29 at 11.07.51 AM.png".
    static func url(for date: Date, in folder: URL) -> URL {
        CFPreferencesAppSynchronize(domain)
        let prefix = CFPreferencesCopyAppValue("name" as CFString, domain) as? String ?? "Screenshot"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium).replacingOccurrences(of: ":", with: ".")
        let base = "\(prefix) \(day.string(from: date)) at \(time)"
        var file = folder.appendingPathComponent(base + ".png")
        var copy = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(base) (\(copy)).png")
            copy += 1
        }
        return file
    }

    /// Writes the clipboard image to `file` as a PNG carrying `dpi`.
    static func save(_ image: Data, dpi: CGFloat, to file: URL) throws {
        try png(image, dpi: dpi).write(to: file, options: .withoutOverwriting)
        let tag = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        _ = tag.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, tag.count, 0, 0) }
        var values = URLResourceValues()
        values.hasHiddenExtension = true
        var file = file
        try? file.setResourceValues(values)
    }

    /// The image as PNG bytes with `dpi` set, re-encoded only when the clipboard's copy differs.
    private static func png(_ image: Data, dpi: CGFloat) throws -> Data {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if CGImageSourceGetType(source) as String? == UTType.png.identifier,
           let current = properties?[kCGImagePropertyDPIWidth] as? CGFloat, abs(current - dpi) < 1 {
            return image
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return png as Data
    }
}
