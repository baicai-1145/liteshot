import AppKit
import CoreGraphics

@MainActor
protocol CaptureOverlayViewDelegate: AnyObject {
    func captureOverlayDidCancel(_ view: CaptureOverlayView)
    func captureOverlayDidRequestCopy(_ view: CaptureOverlayView)
    func captureOverlayDidRequestSave(_ view: CaptureOverlayView)
    func captureOverlayDidRequestOCR(_ view: CaptureOverlayView)
    func captureOverlayDidRequestTranslate(_ view: CaptureOverlayView)
}

@MainActor
final class CaptureOverlayView: NSView {
    weak var delegate: CaptureOverlayViewDelegate?

    private let snapshot: ScreenSnapshot
    private var selection: CGRect = .zero
    private var dragStart: CGPoint?
    private var dragMode: DragMode = .none
    private var selectionBeforeDrag: CGRect = .zero
    private var annotations: [AnnotationShape] = []
    private var activeTool: AnnotationTool?
    private var activeColor: NSColor = .systemPink
    private var activePenPoints: [CGPoint] = []
    private var toolbarButtons: [ToolButton] = []
    private var toolbarFrame: CGRect = .zero
    private var dimensionLabelFrame: CGRect = .zero
    private var windowCandidates: [CGRect] = []
    private var allowsWindowSuggestions = true
    private var isWindowSuggestion = false
    private var isUsingColorPanel = false

    init(snapshot: ScreenSnapshot, initialMode: CaptureMode) {
        self.snapshot = snapshot
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
        windowCandidates = WindowSelectionDetector.visibleWindowRects(for: snapshot, in: bounds)
        wantsLayer = true
        layer?.contentsScale = snapshot.scale
        autoresizingMask = [.width, .height]
        if initialMode == .fullScreen {
            selection = bounds
            allowsWindowSuggestions = false
        }
        rebuildToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectFullScreen() {
        selection = bounds
        allowsWindowSuggestions = false
        isWindowSuggestion = false
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            closeColorPanelIfNeeded()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSnapshot()
        drawDimming()
        drawSelection()
        drawAnnotations()
        drawDimensionLabel()
        drawToolbar()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleToolbarClick(at: point) {
            return
        }

        updateWindowSuggestion(at: point)
        if allowsWindowSuggestions, isWindowSuggestion, selection.contains(point) {
            dragMode = .pendingWindowSelection(selection)
            dragStart = point
            selectionBeforeDrag = selection
            NSCursor.crosshair.set()
            return
        }

        if let handle = selection.resizeHandle(at: point) {
            allowsWindowSuggestions = false
            isWindowSuggestion = false
            activeTool = nil
            dragMode = .resizing(handle)
            dragStart = point
            selectionBeforeDrag = selection
            handle.cursor.set()
            return
        }

        if selection.contains(point), let tool = activeTool {
            allowsWindowSuggestions = false
            isWindowSuggestion = false
            dragMode = .annotating(tool)
            NSCursor.crosshair.set()
            beginAnnotation(tool: tool, at: point)
            return
        }

        if selection.contains(point) {
            allowsWindowSuggestions = false
            isWindowSuggestion = false
            dragMode = .moving
            dragStart = point
            selectionBeforeDrag = selection
            NSCursor.closedHand.set()
            return
        }

        activeTool = nil
        allowsWindowSuggestions = false
        isWindowSuggestion = false
        dragMode = .selecting
        dragStart = point
        selection = CGRect(origin: point, size: .zero)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch dragMode {
        case .none:
            return
        case .pendingWindowSelection(let windowRect):
            guard let dragStart else { return }
            if point.distance(to: dragStart) >= 4 {
                allowsWindowSuggestions = false
                isWindowSuggestion = false
                dragMode = .selecting
                selection = CGRect.from(dragStart, point).intersection(bounds)
            } else {
                selection = windowRect
            }
        case .selecting:
            guard let dragStart else { return }
            selection = CGRect.from(dragStart, point).intersection(bounds)
        case .moving:
            guard let dragStart else { return }
            selection = selectionBeforeDrag.moved(by: point - dragStart, inside: bounds)
        case .resizing(let handle):
            selection = selectionBeforeDrag.resized(using: handle, to: point, inside: bounds)
        case .annotating(let tool):
            updateAnnotation(tool: tool, at: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .annotating(let tool) = dragMode {
            finishAnnotation(tool: tool, at: point)
            updateCursor(at: point)
            dragMode = .none
            return
        }
        if case .pendingWindowSelection(let windowRect) = dragMode {
            selection = windowRect.standardized
            allowsWindowSuggestions = false
            isWindowSuggestion = false
            dragMode = .none
            dragStart = nil
            updateCursor(at: point)
            needsDisplay = true
            return
        }
        dragMode = .none
        dragStart = nil
        selection = selection.standardized
        updateCursor(at: point)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateWindowSuggestion(at: point)
        updateCursor(at: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.captureOverlayDidCancel(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            delegate?.captureOverlayDidCancel(self)
        case 36, 76:
            delegate?.captureOverlayDidRequestCopy(self)
        default:
            super.keyDown(with: event)
        }
    }

    func renderSelection() -> NSImage? {
        guard selection.width >= 2, selection.height >= 2 else { return nil }
        guard let cropped = ImageExporter.croppedImage(from: snapshot, selectionInScreenPoints: selection) else {
            return nil
        }

        let image = NSImage(size: selection.size)
        image.lockFocus()
        cropped.draw(in: CGRect(origin: .zero, size: selection.size))

        NSGraphicsContext.current?.imageInterpolation = .high
        let context = NSGraphicsContext.current?.cgContext
        context?.translateBy(x: -selection.minX, y: -selection.minY)
        drawAnnotations()
        image.unlockFocus()
        return image
    }

    private func drawSnapshot() {
        snapshot.image.draw(in: bounds)
    }

    private func drawDimming() {
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        guard selection.width > 0, selection.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).setClip()
        snapshot.image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSelection() {
        guard selection.width > 0, selection.height > 0 else { return }

        let path = NSBezierPath(rect: selection)
        NSColor.systemBlue.setStroke()
        path.lineWidth = 2
        path.stroke()

        for point in selection.handlePoints {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            NSColor(calibratedWhite: 0.08, alpha: 0.58).setStroke()
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).stroke()
        }
    }

    private func drawDimensionLabel() {
        guard selection.width > 0, selection.height > 0 else { return }
        let text = "\(Int(selection.width * snapshot.scale)) × \(Int(selection.height * snapshot.scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let frame = CGRect(
            x: selection.minX,
            y: min(bounds.maxY - 32, selection.maxY + 8),
            width: size.width + 18,
            height: 26
        )
        dimensionLabelFrame = frame
        NSColor(calibratedWhite: 0.09, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: frame.minX + 9, y: frame.minY + 6), withAttributes: attributes)
    }

    private func drawToolbar() {
        guard selection.width > 0, selection.height > 0, !isWindowSuggestion else { return }
        rebuildToolbar()
        toolbarBackgroundColor.setFill()
        NSBezierPath(roundedRect: toolbarFrame, xRadius: 8, yRadius: 8).fill()

        for button in toolbarButtons {
            let isActive = isToolbarButtonActive(button)
            if isActive {
                NSColor.systemBlue.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: button.frame.insetBy(dx: 3, dy: 4), xRadius: 6, yRadius: 6).fill()
            }

            if let color = button.color {
                color.setFill()
                NSBezierPath(ovalIn: button.frame.insetBy(dx: 10, dy: 10)).fill()
                toolbarColorStroke.setStroke()
                let swatchFrame = button.frame.insetBy(dx: 10, dy: 10)
                NSBezierPath(ovalIn: swatchFrame).stroke()
            } else if let image = NSImage(systemSymbolName: button.symbolName, accessibilityDescription: button.title) {
                let tint = isActive ? NSColor.white : toolbarIconColor
                image.tinted(with: tint).draw(in: button.frame.insetBy(dx: 11, dy: 11))
            }
        }
    }

    private func isToolbarButtonActive(_ button: ToolButton) -> Bool {
        if let tool = button.tool {
            return tool == activeTool
        }
        return false
    }

    private var toolbarBackgroundColor: NSColor {
        isDarkAppearance
            ? NSColor(calibratedWhite: 0.08, alpha: 0.82)
            : NSColor.white.withAlphaComponent(0.92)
    }

    private var toolbarIconColor: NSColor {
        isDarkAppearance ? .white.withAlphaComponent(0.92) : .black.withAlphaComponent(0.86)
    }

    private var toolbarColorStroke: NSColor {
        isDarkAppearance ? .white.withAlphaComponent(0.85) : .black.withAlphaComponent(0.55)
    }

    private func drawAnnotations() {
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

        if !activePenPoints.isEmpty {
            drawPen(points: activePenPoints, color: activeColor)
        }
    }

    private func handleToolbarClick(at point: CGPoint) -> Bool {
        guard !isWindowSuggestion else { return false }
        guard toolbarFrame.contains(point) else { return false }
        guard let button = toolbarButtons.first(where: { $0.frame.contains(point) }) else { return true }

        switch button.action {
        case .cancel:
            delegate?.captureOverlayDidCancel(self)
        case .copy:
            delegate?.captureOverlayDidRequestCopy(self)
        case .save:
            delegate?.captureOverlayDidRequestSave(self)
        case .ocr:
            delegate?.captureOverlayDidRequestOCR(self)
        case .translate:
            delegate?.captureOverlayDidRequestTranslate(self)
        case .tool(let tool):
            activeTool = tool
        case .pickColor:
            showColorPanel()
        }
        needsDisplay = true
        return true
    }

    private func updateCursor(at point: CGPoint) {
        if !isWindowSuggestion, toolbarFrame.contains(point) {
            NSCursor.arrow.set()
        } else if let handle = selection.resizeHandle(at: point) {
            handle.cursor.set()
        } else if selection.contains(point) {
            if activeTool == nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func showColorPanel() {
        let panel = NSColorPanel.shared
        isUsingColorPanel = true
        panel.color = activeColor
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.level = .screenSaver
        panel.orderFrontRegardless()
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        activeColor = sender.color
        needsDisplay = true
    }

    private func closeColorPanelIfNeeded() {
        guard isUsingColorPanel else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.close()
        isUsingColorPanel = false
    }

    private func updateWindowSuggestion(at point: CGPoint) {
        guard allowsWindowSuggestions, activeTool == nil, !toolbarFrame.contains(point) else { return }
        guard let windowRect = windowCandidates.first(where: { $0.contains(point) }) else {
            if isWindowSuggestion {
                selection = .zero
                isWindowSuggestion = false
                needsDisplay = true
            }
            return
        }

        if selection != windowRect || !isWindowSuggestion {
            selection = windowRect
            isWindowSuggestion = true
            needsDisplay = true
        }
    }

    private var isDarkAppearance: Bool {
        if window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private func beginAnnotation(tool: AnnotationTool, at point: CGPoint) {
        dragStart = point
        if tool == .pen {
            activePenPoints = [point]
        }
    }

    private func updateAnnotation(tool: AnnotationTool, at point: CGPoint) {
        if tool == .pen {
            activePenPoints.append(point)
        }
        needsDisplay = true
    }

    private func finishAnnotation(tool: AnnotationTool, at point: CGPoint) {
        guard let dragStart else { return }
        switch tool {
        case .arrow:
            annotations.append(.arrow(start: dragStart, end: point, color: activeColor))
        case .rectangle:
            annotations.append(.rectangle(CGRect.from(dragStart, point), activeColor))
        case .text:
            annotations.append(.text("文本", point, activeColor))
        case .pen:
            annotations.append(.pen(activePenPoints, activeColor))
            activePenPoints = []
        }
        self.dragStart = nil
        dragMode = .none
        needsDisplay = true
    }

    private func rebuildToolbar() {
        guard selection.width > 0, selection.height > 0 else { return }

        let buttonSize: CGFloat = 40
        let spacing: CGFloat = 4
        var buttons: [(String, String, ToolbarAction, AnnotationTool?, NSColor?)] = [
            ("xmark", "取消", .cancel, nil, nil),
            ("doc.on.doc", "复制", .copy, nil, nil),
            ("square.and.arrow.down", "保存", .save, nil, nil),
            ("text.viewfinder", "OCR", .ocr, nil, nil),
            ("character.book.closed", "翻译", .translate, nil, nil),
            (AnnotationTool.arrow.symbolName, "箭头", .tool(.arrow), .arrow, nil),
            (AnnotationTool.rectangle.symbolName, "矩形", .tool(.rectangle), .rectangle, nil),
            (AnnotationTool.pen.symbolName, "画笔", .tool(.pen), .pen, nil),
            ("checkmark", "完成并复制", .copy, nil, nil)
        ]

        if activeTool != nil {
            buttons.insert(("circle.fill", "选择颜色", .pickColor, nil, activeColor), at: buttons.count - 1)
        }

        let width = CGFloat(buttons.count) * buttonSize + CGFloat(buttons.count - 1) * spacing + 16
        let x = min(max(selection.midX - width / 2, bounds.minX + 12), bounds.maxX - width - 12)
        let y: CGFloat
        if selection.minY - 58 > bounds.minY {
            y = selection.minY - 54
        } else {
            y = min(selection.maxY + 10, bounds.maxY - 54)
        }

        toolbarFrame = CGRect(x: x, y: y, width: width, height: 46)
        toolbarButtons = buttons.enumerated().map { index, item in
            ToolButton(
                symbolName: item.0,
                title: item.1,
                action: item.2,
                tool: item.3,
                color: item.4,
                frame: CGRect(
                    x: toolbarFrame.minX + 8 + CGFloat(index) * (buttonSize + spacing),
                    y: toolbarFrame.minY + 3,
                    width: buttonSize,
                    height: buttonSize
                )
            )
        }
    }

    private func drawArrow(start: CGPoint, end: CGPoint, color: NSColor) {
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

    private func drawPen(points: [CGPoint], color: NSColor) {
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

private enum DragMode {
    case none
    case pendingWindowSelection(CGRect)
    case selecting
    case moving
    case resizing(ResizeHandle)
    case annotating(AnnotationTool)
}

private enum ResizeHandle: CaseIterable {
    case minXMinY
    case midXMinY
    case maxXMinY
    case minXMidY
    case maxXMidY
    case minXMaxY
    case midXMaxY
    case maxXMaxY

    @MainActor
    var cursor: NSCursor {
        switch self {
        case .midXMinY, .midXMaxY:
            .resizeUpDown
        case .minXMidY, .maxXMidY:
            .resizeLeftRight
        case .minXMinY, .maxXMaxY:
            DiagonalResizeCursor.northWestSouthEast
        case .maxXMinY, .minXMaxY:
            DiagonalResizeCursor.northEastSouthWest
        }
    }
}

@MainActor
private enum DiagonalResizeCursor {
    static let northWestSouthEast = NSCursor(
        image: image(points: (CGPoint(x: 4, y: 4), CGPoint(x: 14, y: 14))),
        hotSpot: CGPoint(x: 9, y: 9)
    )

    static let northEastSouthWest = NSCursor(
        image: image(points: (CGPoint(x: 14, y: 4), CGPoint(x: 4, y: 14))),
        hotSpot: CGPoint(x: 9, y: 9)
    )

    private static func image(points: (CGPoint, CGPoint)) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        drawLine(from: points.0, to: points.1, color: .white, width: 4)
        drawLine(from: points.0, to: points.1, color: .black, width: 2)
        image.unlockFocus()
        return image
    }

    private static func drawLine(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 4
        for target in [start, end] {
            let direction = target == start ? angle + .pi : angle
            let left = CGPoint(
                x: target.x - arrowLength * cos(direction - .pi / 4),
                y: target.y - arrowLength * sin(direction - .pi / 4)
            )
            let right = CGPoint(
                x: target.x - arrowLength * cos(direction + .pi / 4),
                y: target.y - arrowLength * sin(direction + .pi / 4)
            )
            let head = NSBezierPath()
            head.lineWidth = width
            head.lineCapStyle = .round
            head.move(to: left)
            head.line(to: target)
            head.line(to: right)
            head.stroke()
        }
    }
}

private struct ToolButton {
    let symbolName: String
    let title: String
    let action: ToolbarAction
    let tool: AnnotationTool?
    let color: NSColor?
    let frame: CGRect
}

private enum ToolbarAction {
    case cancel
    case copy
    case save
    case ocr
    case translate
    case tool(AnnotationTool)
    case pickColor
}

private enum WindowSelectionDetector {
    static func visibleWindowRects(for snapshot: ScreenSnapshot, in viewBounds: CGRect) -> [CGRect] {
        guard
            let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return []
        }

        let currentPID = NSRunningApplication.current.processIdentifier
        let displayBounds = normalizedDisplayBounds(for: snapshot)

        return windowList.compactMap { info -> CGRect? in
            let layer = info[kCGWindowLayer as String] as? Int ?? Int.max
            guard layer == 0 else { return nil }

            if let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber, ownerPID.int32Value == currentPID {
                return nil
            }

            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0.01 else { return nil }

            guard
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let rawWindowBounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }

            let windowBounds = normalizedWindowBounds(rawWindowBounds, snapshot: snapshot)
            let localRect = CGRect(
                x: windowBounds.minX - displayBounds.minX,
                y: snapshot.screenFrame.height - (windowBounds.maxY - displayBounds.minY),
                width: windowBounds.width,
                height: windowBounds.height
            ).standardized.intersection(viewBounds).integral

            guard localRect.width >= 40, localRect.height >= 40 else {
                return nil
            }
            return localRect
        }
    }

    private static func normalizedDisplayBounds(for snapshot: ScreenSnapshot) -> CGRect {
        let rawBounds = CGDisplayBounds(CGMainDisplayID())
        let scale = coordinateScale(rawDisplayBounds: rawBounds, snapshot: snapshot)
        guard scale > 0 else { return rawBounds }
        return rawBounds.scaled(by: 1 / scale)
    }

    private static func normalizedWindowBounds(_ rawBounds: CGRect, snapshot: ScreenSnapshot) -> CGRect {
        let rawDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let scale = coordinateScale(rawDisplayBounds: rawDisplayBounds, snapshot: snapshot)
        guard scale > 0 else { return rawBounds }
        return rawBounds.scaled(by: 1 / scale)
    }

    private static func coordinateScale(rawDisplayBounds: CGRect, snapshot: ScreenSnapshot) -> CGFloat {
        let widthScale = rawDisplayBounds.width / max(snapshot.screenFrame.width, 1)
        let heightScale = rawDisplayBounds.height / max(snapshot.screenFrame.height, 1)
        let scale = max(widthScale, heightScale)
        return scale > 1.1 ? scale : 1
    }
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let output = NSImage(size: size)
        output.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceAtop)
        output.unlockFocus()
        output.isTemplate = false
        return output
    }
}

private extension CGRect {
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(
            x: origin.x * scale,
            y: origin.y * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }
}

private extension CGRect {
    static func from(_ first: CGPoint, _ second: CGPoint) -> CGRect {
        CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(first.x - second.x),
            height: abs(first.y - second.y)
        )
    }

    var handlePoints: [CGPoint] {
        ResizeHandle.allCases.map { point(for: $0) }
    }

    func resizeHandle(at point: CGPoint, tolerance: CGFloat = 10) -> ResizeHandle? {
        guard width > 0, height > 0 else { return nil }
        return ResizeHandle.allCases.first { handle in
            let handlePoint = self.point(for: handle)
            return abs(handlePoint.x - point.x) <= tolerance && abs(handlePoint.y - point.y) <= tolerance
        }
    }

    func point(for handle: ResizeHandle) -> CGPoint {
        switch handle {
        case .minXMinY:
            CGPoint(x: minX, y: minY)
        case .midXMinY:
            CGPoint(x: midX, y: minY)
        case .maxXMinY:
            CGPoint(x: maxX, y: minY)
        case .minXMidY:
            CGPoint(x: minX, y: midY)
        case .maxXMidY:
            CGPoint(x: maxX, y: midY)
        case .minXMaxY:
            CGPoint(x: minX, y: maxY)
        case .midXMaxY:
            CGPoint(x: midX, y: maxY)
        case .maxXMaxY:
            CGPoint(x: maxX, y: maxY)
        }
    }

    func moved(by delta: CGSize, inside bounds: CGRect) -> CGRect {
        var rect = offsetBy(dx: delta.width, dy: delta.height)
        if rect.minX < bounds.minX {
            rect.origin.x = bounds.minX
        }
        if rect.minY < bounds.minY {
            rect.origin.y = bounds.minY
        }
        if rect.maxX > bounds.maxX {
            rect.origin.x = bounds.maxX - rect.width
        }
        if rect.maxY > bounds.maxY {
            rect.origin.y = bounds.maxY - rect.height
        }
        return rect
    }

    func resized(using handle: ResizeHandle, to point: CGPoint, inside bounds: CGRect) -> CGRect {
        let clamped = CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        var minX = self.minX
        var minY = self.minY
        var maxX = self.maxX
        var maxY = self.maxY

        switch handle {
        case .minXMinY:
            minX = clamped.x
            minY = clamped.y
        case .midXMinY:
            minY = clamped.y
        case .maxXMinY:
            maxX = clamped.x
            minY = clamped.y
        case .minXMidY:
            minX = clamped.x
        case .maxXMidY:
            maxX = clamped.x
        case .minXMaxY:
            minX = clamped.x
            maxY = clamped.y
        case .midXMaxY:
            maxY = clamped.y
        case .maxXMaxY:
            maxX = clamped.x
            maxY = clamped.y
        }

        let minimumSize: CGFloat = 12
        var rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
        if rect.width < minimumSize {
            rect.size.width = minimumSize
        }
        if rect.height < minimumSize {
            rect.size.height = minimumSize
        }
        return rect.intersection(bounds)
    }
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGSize {
    CGSize(width: lhs.x - rhs.x, height: lhs.y - rhs.y)
}

private extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        hypot(x - point.x, y - point.y)
    }
}
