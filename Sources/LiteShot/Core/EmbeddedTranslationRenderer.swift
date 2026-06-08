import AppKit

enum EmbeddedTranslationRenderer {
    static func render(image: NSImage, lines: [TranslatedTextLine]) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let canvasSize = image.size
        let output = NSImage(size: canvasSize)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        output.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: canvasSize), from: .zero, operation: .sourceOver, fraction: 1)

        for line in lines where !line.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let baseRect = imageRect(from: line.boundingBox, imageSize: canvasSize)
            let renderRect = expandedRect(for: baseRect, text: line.translatedText, imageSize: canvasSize)
            let background = sampledBackgroundColor(bitmap: bitmap, rect: renderRect, imageSize: canvasSize)
            let foreground = readableTextColor(on: background)

            drawBackground(in: renderRect, color: background)
            drawText(line.translatedText, in: renderRect.insetBy(dx: 3, dy: 2), color: foreground)
        }

        output.unlockFocus()
        return output.normalizedBitmapImage()
    }

    private static func imageRect(from normalizedBox: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedBox.minX * imageSize.width,
            y: normalizedBox.minY * imageSize.height,
            width: normalizedBox.width * imageSize.width,
            height: normalizedBox.height * imageSize.height
        ).standardized
    }

    private static func expandedRect(for rect: CGRect, text: String, imageSize: CGSize) -> CGRect {
        let estimatedCharacters = max(CGFloat(text.count), 1)
        let expansion = min(max((estimatedCharacters / 16) * 0.18, 0), 0.85)
        let dx = max(4, rect.width * expansion)
        let dy = max(3, rect.height * 0.35)
        return rect
            .insetBy(dx: -dx, dy: -dy)
            .clamped(to: CGRect(origin: .zero, size: imageSize))
    }

    private static func drawBackground(in rect: CGRect, color: NSColor) {
        color.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: min(4, rect.height / 4), yRadius: min(4, rect.height / 4)).fill()
    }

    private static func drawText(_ text: String, in rect: CGRect, color: NSColor) {
        guard rect.width > 2, rect.height > 2 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping

        var fontSize = min(max(rect.height * 0.72, 7), 30)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = CGSize.zero

        while fontSize >= 6 {
            attributes = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
            measured = (text as NSString).boundingRect(
                with: CGSize(width: rect.width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            ).size
            if measured.height <= rect.height * 1.04 {
                break
            }
            fontSize -= 0.6
        }

        let drawRect = CGRect(
            x: rect.minX,
            y: rect.midY - min(measured.height, rect.height) / 2,
            width: rect.width,
            height: rect.height
        )
        (text as NSString).draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
    }

    private static func sampledBackgroundColor(bitmap: NSBitmapImageRep, rect: CGRect, imageSize: CGSize) -> NSColor {
        let points = samplePoints(around: rect)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0

        for point in points {
            let pixelX = Int((point.x / max(imageSize.width, 1)) * CGFloat(bitmap.pixelsWide))
            let pixelYFromBottom = Int((point.y / max(imageSize.height, 1)) * CGFloat(bitmap.pixelsHigh))
            let pixelY = bitmap.pixelsHigh - pixelYFromBottom - 1
            guard
                pixelX >= 0,
                pixelX < bitmap.pixelsWide,
                pixelY >= 0,
                pixelY < bitmap.pixelsHigh,
                let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB)
            else {
                continue
            }
            red += color.redComponent
            green += color.greenComponent
            blue += color.blueComponent
            count += 1
        }

        guard count > 0 else {
            return NSColor(calibratedWhite: 0.08, alpha: 1)
        }

        return NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
    }

    private static func samplePoints(around rect: CGRect) -> [CGPoint] {
        let expanded = rect.insetBy(dx: -max(4, rect.width * 0.08), dy: -max(3, rect.height * 0.4))
        return [
            CGPoint(x: expanded.minX, y: expanded.minY),
            CGPoint(x: expanded.midX, y: expanded.minY),
            CGPoint(x: expanded.maxX, y: expanded.minY),
            CGPoint(x: expanded.minX, y: expanded.midY),
            CGPoint(x: expanded.maxX, y: expanded.midY),
            CGPoint(x: expanded.minX, y: expanded.maxY),
            CGPoint(x: expanded.midX, y: expanded.maxY),
            CGPoint(x: expanded.maxX, y: expanded.maxY)
        ]
    }

    private static func readableTextColor(on background: NSColor) -> NSColor {
        guard let color = background.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance > 0.52 ? NSColor(calibratedWhite: 0.04, alpha: 1) : .white
    }
}

private extension CGRect {
    func clamped(to bounds: CGRect) -> CGRect {
        var rect = self.standardized
        if rect.minX < bounds.minX {
            rect.origin.x = bounds.minX
        }
        if rect.minY < bounds.minY {
            rect.origin.y = bounds.minY
        }
        if rect.maxX > bounds.maxX {
            rect.origin.x = max(bounds.minX, bounds.maxX - rect.width)
        }
        if rect.maxY > bounds.maxY {
            rect.origin.y = max(bounds.minY, bounds.maxY - rect.height)
        }
        rect.size.width = min(rect.width, bounds.width)
        rect.size.height = min(rect.height, bounds.height)
        return rect
    }
}

private extension NSImage {
    func normalizedBitmapImage() -> NSImage {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return self
        }
        return NSImage(cgImage: cgImage, size: size)
    }
}
