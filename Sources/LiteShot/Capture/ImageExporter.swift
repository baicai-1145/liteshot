import AppKit

enum ImageExporter {
    static func croppedImage(from snapshot: ScreenSnapshot, selectionInScreenPoints selection: CGRect) -> NSImage? {
        guard let cgImage = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let imageHeight = CGFloat(cgImage.height)
        let pixelRect = CGRect(
            x: selection.minX * snapshot.scale,
            y: imageHeight - selection.maxY * snapshot.scale,
            width: selection.width * snapshot.scale,
            height: selection.height * snapshot.scale
        ).integral

        guard let cropped = cgImage.cropping(to: pixelRect) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: selection.size)
    }

    static func encodedData(for image: NSImage, format: ImageFormat) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        let properties: [NSBitmapImageRep.PropertyKey: Any]
        switch format {
        case .png:
            properties = [:]
        case .jpeg:
            properties = [.compressionFactor: 0.92]
        }

        return rep.representation(using: format.bitmapType, properties: properties)
    }

    static func write(_ image: NSImage, format: ImageFormat, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "截图 \(formatter.string(from: Date())).\(format.fileExtension)"
        let url = directory.appendingPathComponent(name)
        guard let data = encodedData(for: image, format: format) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url, options: [.atomic])
        return url
    }
}

enum ExportError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "图片编码失败。"
    }
}
