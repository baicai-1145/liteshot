import AppKit
import ImageIO

struct CapturedImage {
    let cgImage: CGImage
    let size: CGSize

    var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    var nsImage: NSImage {
        NSImage(cgImage: cgImage, size: size)
    }
}

enum ImageExporter {
    static func capturedImage(
        from snapshot: ScreenSnapshot,
        selectionInScreenPoints selection: CGRect,
        annotations: [AnnotationShape]
    ) -> CapturedImage? {
        guard let baseImage = capturedCGImage(from: snapshot, selectionInScreenPoints: selection) else {
            return nil
        }

        guard !annotations.isEmpty else {
            return CapturedImage(cgImage: baseImage, size: selection.size)
        }

        let renderedImage = renderAnnotations(
            baseImage: baseImage,
            canvasSize: selection.size,
            selection: selection,
            annotations: annotations
        ) ?? baseImage
        return CapturedImage(cgImage: renderedImage, size: selection.size)
    }

    private static func capturedCGImage(from snapshot: ScreenSnapshot, selectionInScreenPoints selection: CGRect) -> CGImage? {
        let scaleX = CGFloat(snapshot.frozenImage.width) / max(snapshot.screenFrame.width, 1)
        let scaleY = CGFloat(snapshot.frozenImage.height) / max(snapshot.screenFrame.height, 1)
        let pixelRect = CGRect(
            x: selection.minX * scaleX,
            y: (snapshot.screenFrame.height - selection.maxY) * scaleY,
            width: selection.width * scaleX,
            height: selection.height * scaleY
        )
            .integral
            .intersection(CGRect(x: 0, y: 0, width: snapshot.frozenImage.width, height: snapshot.frozenImage.height))

        guard pixelRect.width > 0, pixelRect.height > 0 else {
            return nil
        }
        return snapshot.frozenImage.cropping(to: pixelRect)
    }

    static func encodedData(for image: CapturedImage, format: ImageFormat) -> Data? {
        encodedData(for: image.cgImage, format: format)
    }

    static func encodedData(for image: NSImage, format: ImageFormat) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return encodedData(for: cgImage, format: format)
    }

    static func encodedData(for cgImage: CGImage, format: ImageFormat) -> Data? {
        let data = NSMutableData()
        let type: CFString
        let properties: CFDictionary
        switch format {
        case .png:
            type = "public.png" as CFString
            properties = [:] as CFDictionary
        case .jpeg:
            type = "public.jpeg" as CFString
            properties = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        }

        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    static func write(_ image: CapturedImage, format: ImageFormat, directory: URL) throws -> URL {
        (try writeEncodedImage(
            pixelSize: image.pixelSize,
            format: format,
            directory: directory,
            encodedData: { encodedData(for: image, format: format) }
        )).url
    }

    static func write(_ image: NSImage, format: ImageFormat, directory: URL) throws -> URL {
        (try writeEncodedImage(
            pixelSize: pixelSize(for: image),
            format: format,
            directory: directory,
            encodedData: { encodedData(for: image, format: format) }
        )).url
    }

    private static func writeEncodedImage(
        pixelSize: CGSize,
        format: ImageFormat,
        directory: URL,
        encodedData: () -> Data?
    ) throws -> (url: URL, pixelSize: CGSize) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "截图 \(formatter.string(from: Date())).\(format.fileExtension)"
        let url = directory.appendingPathComponent(name)
        guard let data = autoreleasepool(invoking: encodedData) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url, options: [.atomic])
        return (url, pixelSize)
    }

    private static func pixelSize(for image: NSImage) -> CGSize {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image.size
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    private static func renderAnnotations(
        baseImage: CGImage,
        canvasSize: CGSize,
        selection: CGRect,
        annotations: [AnnotationShape]
    ) -> CGImage? {
        let width = max(baseImage.width, 1)
        let height = max(baseImage.height, 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let scaleX = CGFloat(width) / max(canvasSize.width, 1)
        let scaleY = CGFloat(height) / max(canvasSize.height, 1)
        context.scaleBy(x: scaleX, y: scaleY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSImage(cgImage: baseImage, size: canvasSize)
            .draw(in: CGRect(origin: .zero, size: canvasSize))
        context.translateBy(x: -selection.minX, y: -selection.minY)
        draw(annotations)
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }

    private static func draw(_ annotations: [AnnotationShape]) {
        for annotation in annotations {
            switch annotation {
            case let .arrow(start, end, color):
                drawArrow(start: start, end: end, color: color)
            case let .rectangle(rect, color):
                color.setStroke()
                let path = NSBezierPath(rect: rect.standardized)
                path.lineWidth = 3
                path.stroke()
            case let .text(text, point, color):
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                    .foregroundColor: color
                ]
                text.draw(at: point, withAttributes: attributes)
            case let .pen(points, color):
                drawPen(points: points, color: color)
            }
        }
    }

    private static func drawArrow(start: CGPoint, end: CGPoint, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 14
        let spread: CGFloat = .pi / 7
        let left = CGPoint(x: end.x - arrowLength * cos(angle - spread), y: end.y - arrowLength * sin(angle - spread))
        let right = CGPoint(x: end.x - arrowLength * cos(angle + spread), y: end.y - arrowLength * sin(angle + spread))

        let head = NSBezierPath()
        head.lineWidth = 3
        head.lineCapStyle = .round
        head.move(to: left)
        head.line(to: end)
        head.line(to: right)
        head.stroke()
    }

    private static func drawPen(points: [CGPoint], color: NSColor) {
        guard points.count > 1 else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.stroke()
    }
}

enum ExportError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        "图片编码失败。"
    }
}
