import AppKit

enum PasteboardWriter {
    static func copy(_ image: CapturedImage) {
        if let data = autoreleasepool(invoking: { ImageExporter.encodedData(for: image, format: .png) }) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }

    static func copy(image: NSImage) {
        if let data = autoreleasepool(invoking: { ImageExporter.encodedData(for: image, format: .png) }) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        }
    }

    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
