import AppKit
import CoreGraphics
import QuartzCore

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
    private var activeHue: CGFloat = 0
    private var activeSaturation: CGFloat = 0.85
    private var activeBrightness: CGFloat = 1
    private var activeAlpha: CGFloat = 1
    private var activeAnnotationEnd: CGPoint?
    private var activePenPoints: [CGPoint] = []
    private var toolbarButtons: [ToolButton] = []
    private var toolbarFrame: CGRect = .zero
    private var hoveredToolbarButton: ToolButton?
    private var isColorPickerVisible = false
    private var colorPickerFrame: CGRect = .zero
    private var colorHueSliderFrame: CGRect = .zero
    private var colorBrightnessSliderFrame: CGRect = .zero
    private var colorSwatchFrames: [(color: NSColor, frame: CGRect)] = []
    private var dimensionLabelFrame: CGRect = .zero
    private var windowCandidates: [CGRect] = []
    private var allowsWindowSuggestions = true
    private var isWindowSuggestion = false
    private let visualOverlay = CaptureVisualOverlay()

    init(snapshot: ScreenSnapshot, initialMode: CaptureMode) {
        self.snapshot = snapshot
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
        let backingLayer = CALayer()
        backingLayer.frame = bounds
        backingLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer = backingLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        configureFrozenImageLayer()
        visualOverlay.onMouseDown = { [weak self] point in
            self?.handleVisualOverlayMouseDown(at: point)
        }
        visualOverlay.onMouseDragged = { [weak self] point in
            self?.handleVisualOverlayMouseDragged(at: point)
        }
        visualOverlay.onMouseUp = { [weak self] point in
            self?.handleVisualOverlayMouseUp(at: point)
        }
        visualOverlay.onMouseMoved = { [weak self] point in
            self?.handleVisualOverlayMouseMoved(at: point)
        }
        syncColorControls(from: activeColor)
        windowCandidates = WindowSelectionDetector.visibleWindowRects(for: snapshot, in: bounds)
        autoresizingMask = [.width, .height]
        if initialMode == .fullScreen {
            selection = bounds
            allowsWindowSuggestions = false
        }
        rebuildToolbar()
        refreshVisualOverlay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func selectFullScreen() {
        selection = bounds
        allowsWindowSuggestions = false
        isWindowSuggestion = false
        refreshVisualOverlay()
    }

    func closeVisualOverlay() {
        visualOverlay.close()
    }

    static func closeAllVisualOverlays() {
        CaptureVisualOverlay.closeAllPanels()
    }

    override var isOpaque: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
        configureFrozenImageLayer()
        if let window {
            visualOverlay.show(screenFrame: snapshot.screenFrame, level: NSWindow.Level(rawValue: window.level.rawValue + 1))
            refreshVisualOverlay()
        } else {
            visualOverlay.hide()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            visualOverlay.hide()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard layer == nil else { return }
        NSImage(cgImage: snapshot.frozenImage, size: bounds.size).draw(in: bounds)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configureFrozenImageLayer()
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }

    private func configureFrozenImageLayer() {
        guard let layer else { return }
        layer.contents = snapshot.frozenImage
        layer.contentsGravity = .resize
        layer.contentsScale = snapshot.scale
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        layer.masksToBounds = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if handleColorPickerMouseDown(at: point) {
            return
        }
        if handleToolbarClick(at: point) {
            return
        }
        updateHoveredToolbarButton(at: nil)

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
            isColorPickerVisible = false
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
        isColorPickerVisible = false
        allowsWindowSuggestions = false
        isWindowSuggestion = false
        dragMode = .selecting
        dragStart = point
        selection = CGRect(origin: point, size: .zero)
        NSCursor.crosshair.set()
        refreshVisualOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredToolbarButton(at: nil)

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
        case .pickingHue:
            updateActiveColorFromHueSlider(at: point)
        case .pickingBrightness:
            updateActiveColorFromBrightnessSlider(at: point)
        }
        refreshVisualOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if case .pickingHue = dragMode {
            dragMode = .none
            updateCursor(at: point)
            return
        }
        if case .pickingBrightness = dragMode {
            dragMode = .none
            updateCursor(at: point)
            return
        }
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
            refreshVisualOverlay()
            return
        }
        dragMode = .none
        dragStart = nil
        selection = selection.standardized
        updateCursor(at: point)
        refreshVisualOverlay()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateWindowSuggestion(at: point)
        updateHoveredToolbarButton(at: point)
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

    private func refreshVisualOverlay() {
        if selection.width > 0, selection.height > 0 {
            rebuildToolbar()
            drawDimensionLabelLayoutOnly()
            if isColorPickerVisible, activeTool != nil {
                updateColorPickerLayout()
            }
        } else {
            toolbarButtons = []
            toolbarFrame = .zero
            dimensionLabelFrame = .zero
        }

        visualOverlay.update(
            screenFrame: snapshot.screenFrame,
            bounds: bounds,
            selection: selection,
            scale: snapshot.scale,
            isWindowSuggestion: isWindowSuggestion,
            annotations: annotations,
            activeAnnotationPreview: activeAnnotationPreview,
            activePenPoints: activePenPoints,
            toolbarFrame: toolbarFrame,
            toolbarButtons: toolbarButtons,
            hoveredToolbarButton: hoveredToolbarButton,
            activeTool: activeTool,
            activeColor: activeColor,
            activeHue: activeHue,
            activeBrightness: activeBrightness,
            colorPickerFrame: colorPickerFrame,
            colorHueSliderFrame: colorHueSliderFrame,
            colorBrightnessSliderFrame: colorBrightnessSliderFrame,
            colorSwatchFrames: colorSwatchFrames,
            isColorPickerVisible: isColorPickerVisible && activeTool != nil,
            dimensionLabelFrame: dimensionLabelFrame,
            isDarkAppearance: isDarkAppearance
        )
    }

    private func handleVisualOverlayMouseDown(at point: CGPoint) {
        if handleColorPickerMouseDown(at: point) {
            return
        }
        if handleToolbarClick(at: point) {
            return
        }
    }

    private func handleVisualOverlayMouseDragged(at point: CGPoint) {
        switch dragMode {
        case .pickingHue:
            updateActiveColorFromHueSlider(at: point)
        case .pickingBrightness:
            updateActiveColorFromBrightnessSlider(at: point)
        default:
            break
        }
    }

    private func handleVisualOverlayMouseUp(at point: CGPoint) {
        if case .pickingHue = dragMode {
            dragMode = .none
            updateCursor(at: point)
        } else if case .pickingBrightness = dragMode {
            dragMode = .none
            updateCursor(at: point)
        }
    }

    private func handleVisualOverlayMouseMoved(at point: CGPoint) {
        updateHoveredToolbarButton(at: point)
        updateCursor(at: point)
    }

    func canRenderSelection() -> Bool {
        selection.width >= 2 && selection.height >= 2
    }

    func triggerToolbarCompletionForMemorySmoke() -> Bool {
        guard canRenderSelection() else { return false }
        rebuildToolbar()
        guard let button = toolbarButtons.first(where: { button in
            if case .copy = button.action {
                return true
            }
            return false
        }) else {
            return false
        }
        return handleToolbarClick(at: CGPoint(x: button.frame.midX, y: button.frame.midY))
    }

    func showAnnotationPreviewForMemorySmoke() -> Bool {
        guard canRenderSelection() else { return false }
        let insetSelection = selection.standardized.insetBy(dx: max(24, selection.width * 0.12), dy: max(24, selection.height * 0.12))
        let drawingRect = insetSelection.width > 80 && insetSelection.height > 80 ? insetSelection : selection.standardized

        activeTool = .pen
        isWindowSuggestion = false
        allowsWindowSuggestions = false
        isColorPickerVisible = false
        annotations = [
            .arrow(
                start: CGPoint(x: drawingRect.minX, y: drawingRect.minY),
                end: CGPoint(x: drawingRect.midX, y: drawingRect.midY),
                color: .systemRed
            ),
            .rectangle(
                CGRect(x: drawingRect.midX, y: drawingRect.midY, width: max(32, drawingRect.width * 0.35), height: max(24, drawingRect.height * 0.28)),
                .systemBlue
            )
        ]
        dragMode = .annotating(.pen)
        dragStart = CGPoint(x: drawingRect.minX, y: drawingRect.maxY)
        activeAnnotationEnd = CGPoint(x: drawingRect.maxX, y: drawingRect.minY)
        activePenPoints = [
            CGPoint(x: drawingRect.minX, y: drawingRect.maxY),
            CGPoint(x: drawingRect.midX, y: drawingRect.maxY - drawingRect.height * 0.22),
            CGPoint(x: drawingRect.maxX, y: drawingRect.minY)
        ]
        refreshVisualOverlay()
        return true
    }

    func renderSelection(overlayIsAlreadyClosed: Bool = false) -> CapturedImage? {
        autoreleasepool {
            guard canRenderSelection() else { return nil }
            let captureWindow = window
            var shouldRestoreWindow = true
            let shouldManageWindowVisibility = !overlayIsAlreadyClosed

            if shouldManageWindowVisibility {
                captureWindow?.orderOut(nil)
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            defer {
                if shouldManageWindowVisibility && shouldRestoreWindow {
                    captureWindow?.orderFrontRegardless()
                    captureWindow?.makeKey()
                }
            }

            guard let image = ImageExporter.capturedImage(
                from: snapshot,
                selectionInScreenPoints: selection,
                annotations: annotations
            ) else {
                return nil
            }

            shouldRestoreWindow = false
            return image
        }
    }

    private func drawDimming() {
        NSColor.black.withAlphaComponent(0.42).setFill()
        bounds.fill()

        guard selection.width > 0, selection.height > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.fill(selection)
        context.restoreGState()
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
        drawDimensionLabelLayoutOnly()
        let text = dimensionText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let frame = dimensionLabelFrame
        NSColor(calibratedWhite: 0.09, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: frame.minX + 9, y: frame.minY + 6), withAttributes: attributes)
    }

    private var dimensionText: String {
        "\(Int(selection.width * snapshot.scale)) × \(Int(selection.height * snapshot.scale))"
    }

    private func drawDimensionLabelLayoutOnly() {
        guard selection.width > 0, selection.height > 0 else {
            dimensionLabelFrame = .zero
            return
        }
        let text = dimensionText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        dimensionLabelFrame = CGRect(
            x: selection.minX,
            y: min(bounds.maxY - 32, selection.maxY + 8),
            width: size.width + 18,
            height: 26
        )
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
        if isColorPickerVisible, activeTool != nil {
            drawColorPicker()
        } else {
            drawToolbarTooltip()
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

    private var tooltipBackgroundColor: NSColor {
        isDarkAppearance
            ? NSColor(calibratedWhite: 0.10, alpha: 0.92)
            : NSColor.white.withAlphaComponent(0.96)
    }

    private var tooltipTextColor: NSColor {
        isDarkAppearance ? .white.withAlphaComponent(0.95) : .black.withAlphaComponent(0.88)
    }

    private var colorPickerBackgroundColor: NSColor {
        isDarkAppearance
            ? NSColor(calibratedWhite: 0.08, alpha: 0.94)
            : NSColor.white.withAlphaComponent(0.97)
    }

    private func drawToolbarTooltip() {
        guard let button = hoveredToolbarButton else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: tooltipTextColor
        ]
        let textSize = button.title.size(withAttributes: attributes)
        let tooltipSize = CGSize(width: textSize.width + 18, height: 28)
        let x = min(max(button.frame.midX - tooltipSize.width / 2, bounds.minX + 8), bounds.maxX - tooltipSize.width - 8)
        let y: CGFloat
        if toolbarFrame.maxY + tooltipSize.height + 8 <= bounds.maxY {
            y = toolbarFrame.maxY + 6
        } else {
            y = toolbarFrame.minY - tooltipSize.height - 6
        }
        let tooltipFrame = CGRect(origin: CGPoint(x: x, y: y), size: tooltipSize)

        tooltipBackgroundColor.setFill()
        NSBezierPath(roundedRect: tooltipFrame, xRadius: 6, yRadius: 6).fill()
        toolbarColorStroke.setStroke()
        let border = NSBezierPath(roundedRect: tooltipFrame, xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()
        button.title.draw(
            at: CGPoint(x: tooltipFrame.minX + 9, y: tooltipFrame.minY + 7),
            withAttributes: attributes
        )
    }

    private func drawColorPicker() {
        updateColorPickerLayout()

        colorPickerBackgroundColor.setFill()
        NSBezierPath(roundedRect: colorPickerFrame, xRadius: 8, yRadius: 8).fill()
        toolbarColorStroke.setStroke()
        let border = NSBezierPath(roundedRect: colorPickerFrame, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        for item in colorSwatchFrames {
            item.color.setFill()
            NSBezierPath(ovalIn: item.frame).fill()
            (isSameColor(item.color, activeColor) ? NSColor.systemBlue : toolbarColorStroke).setStroke()
            let swatchBorder = NSBezierPath(ovalIn: item.frame.insetBy(dx: -2, dy: -2))
            swatchBorder.lineWidth = isSameColor(item.color, activeColor) ? 2 : 1
            swatchBorder.stroke()
        }

        drawHueSlider()
        drawBrightnessSlider()
    }

    private func drawHueSlider() {
        let colors: [NSColor] = [
            .systemRed,
            .systemYellow,
            .systemGreen,
            .systemCyan,
            .systemBlue,
            .systemPurple,
            .systemRed
        ]
        if let gradient = NSGradient(colors: colors) {
            gradient.draw(in: colorHueSliderFrame, angle: 0)
        }
        drawSliderBorder(colorHueSliderFrame)
        drawSliderIndicator(at: colorHueSliderFrame.minX + activeHue * colorHueSliderFrame.width, in: colorHueSliderFrame)
    }

    private func drawBrightnessSlider() {
        let brightColor = NSColor(calibratedHue: activeHue, saturation: activeSaturation, brightness: 1, alpha: 1)
        if let gradient = NSGradient(colors: [.black, brightColor]) {
            gradient.draw(in: colorBrightnessSliderFrame, angle: 0)
        }
        drawSliderBorder(colorBrightnessSliderFrame)
        drawSliderIndicator(at: colorBrightnessSliderFrame.minX + activeBrightness * colorBrightnessSliderFrame.width, in: colorBrightnessSliderFrame)
    }

    private func drawSliderBorder(_ frame: CGRect) {
        toolbarColorStroke.setStroke()
        let border = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawSliderIndicator(at x: CGFloat, in frame: CGRect) {
        let indicatorFrame = CGRect(x: x - 2, y: frame.minY - 3, width: 4, height: frame.height + 6)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: indicatorFrame, xRadius: 2, yRadius: 2).fill()
        NSColor.black.withAlphaComponent(0.72).setStroke()
        let border = NSBezierPath(roundedRect: indicatorFrame, xRadius: 2, yRadius: 2)
        border.lineWidth = 1
        border.stroke()
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
            return true
        case .copy:
            delegate?.captureOverlayDidRequestCopy(self)
            return true
        case .save:
            delegate?.captureOverlayDidRequestSave(self)
            return true
        case .ocr:
            delegate?.captureOverlayDidRequestOCR(self)
            return true
        case .translate:
            delegate?.captureOverlayDidRequestTranslate(self)
            return true
        case .tool(let tool):
            activeTool = tool
            isColorPickerVisible = true
        case .pickColor:
            isColorPickerVisible.toggle()
        }
        refreshVisualOverlay()
        return true
    }

    private func handleColorPickerMouseDown(at point: CGPoint) -> Bool {
        guard isColorPickerVisible, activeTool != nil else { return false }
        updateColorPickerLayout()

        if let swatch = colorSwatchFrames.first(where: { $0.frame.contains(point) }) {
            syncColorControls(from: swatch.color)
            refreshVisualOverlay()
            return true
        }

        if colorHueSliderFrame.contains(point) {
            updateActiveColorFromHueSlider(at: point)
            dragMode = .pickingHue
            return true
        }

        if colorBrightnessSliderFrame.contains(point) {
            updateActiveColorFromBrightnessSlider(at: point)
            dragMode = .pickingBrightness
            return true
        }

        if colorPickerFrame.contains(point) {
            return true
        }

        isColorPickerVisible = false
        refreshVisualOverlay()
        return false
    }

    private func updateHoveredToolbarButton(at point: CGPoint?) {
        let nextButton: ToolButton?
        if let point, !isWindowSuggestion, toolbarFrame.contains(point) {
            rebuildToolbar()
            nextButton = toolbarButtons.first { $0.frame.contains(point) }
        } else {
            nextButton = nil
        }

        guard hoveredToolbarButton?.title != nextButton?.title else { return }
        hoveredToolbarButton = nextButton
        refreshVisualOverlay()
    }

    private func updateCursor(at point: CGPoint) {
        if isColorPickerVisible, colorPickerFrame.contains(point) {
            NSCursor.arrow.set()
        } else if isWindowSuggestion {
            NSCursor.arrow.set()
        } else if !isWindowSuggestion, toolbarFrame.contains(point) {
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

    private func updateColorPickerLayout() {
        rebuildToolbar()
        let anchor = toolbarButtons.first { $0.action.isColorPicker }
        let anchorFrame = anchor?.frame ?? toolbarFrame
        let pickerSize = CGSize(width: 240, height: 104)
        let x = min(max(anchorFrame.midX - pickerSize.width / 2, bounds.minX + 8), bounds.maxX - pickerSize.width - 8)
        let y: CGFloat
        if toolbarFrame.maxY + pickerSize.height + 8 <= bounds.maxY {
            y = toolbarFrame.maxY + 6
        } else {
            y = toolbarFrame.minY - pickerSize.height - 6
        }
        colorPickerFrame = CGRect(origin: CGPoint(x: x, y: y), size: pickerSize)

        let padding: CGFloat = 12
        let swatchSize: CGFloat = 22
        let swatchSpacing: CGFloat = 5
        let swatchY = colorPickerFrame.maxY - padding - swatchSize
        colorSwatchFrames = presetAnnotationColors.enumerated().map { index, color in
            let x = colorPickerFrame.minX + padding + CGFloat(index) * (swatchSize + swatchSpacing)
            return (color, CGRect(x: x, y: swatchY, width: swatchSize, height: swatchSize))
        }

        colorHueSliderFrame = CGRect(
            x: colorPickerFrame.minX + padding,
            y: colorPickerFrame.minY + 39,
            width: colorPickerFrame.width - padding * 2,
            height: 12
        )
        colorBrightnessSliderFrame = CGRect(
            x: colorPickerFrame.minX + padding,
            y: colorPickerFrame.minY + 16,
            width: colorPickerFrame.width - padding * 2,
            height: 12
        )
    }

    private var presetAnnotationColors: [NSColor] {
        [
            .systemRed,
            .systemOrange,
            .systemYellow,
            .systemGreen,
            .systemBlue,
            .systemPurple,
            .white,
            .black
        ]
    }

    private func syncColorControls(from color: NSColor) {
        let hsba = hsbaComponents(for: color)
        activeColor = color
        activeHue = hsba.hue
        activeSaturation = hsba.saturation
        activeBrightness = hsba.brightness
        activeAlpha = hsba.alpha
    }

    private func hsbaComponents(for sourceColor: NSColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat) {
        let color = sourceColor.usingColorSpace(.deviceRGB) ?? sourceColor
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness, alpha)
    }

    private func updateActiveColorFromHueSlider(at point: CGPoint) {
        activeHue = normalizedSliderValue(point.x, in: colorHueSliderFrame)
        if activeSaturation < 0.05 {
            activeSaturation = 0.85
        }
        updateActiveColorFromControls()
        refreshVisualOverlay()
    }

    private func updateActiveColorFromBrightnessSlider(at point: CGPoint) {
        activeBrightness = normalizedSliderValue(point.x, in: colorBrightnessSliderFrame)
        updateActiveColorFromControls()
        refreshVisualOverlay()
    }

    private func updateActiveColorFromControls() {
        activeColor = NSColor(
            calibratedHue: activeHue,
            saturation: activeSaturation,
            brightness: activeBrightness,
            alpha: activeAlpha
        )
    }

    private func normalizedSliderValue(_ x: CGFloat, in frame: CGRect) -> CGFloat {
        guard frame.width > 0 else { return 0 }
        return min(max((x - frame.minX) / frame.width, 0), 1)
    }

    private func isSameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
        var leftRed: CGFloat = 0
        var leftGreen: CGFloat = 0
        var leftBlue: CGFloat = 0
        var leftAlpha: CGFloat = 0
        var rightRed: CGFloat = 0
        var rightGreen: CGFloat = 0
        var rightBlue: CGFloat = 0
        var rightAlpha: CGFloat = 0
        left.getRed(&leftRed, green: &leftGreen, blue: &leftBlue, alpha: &leftAlpha)
        right.getRed(&rightRed, green: &rightGreen, blue: &rightBlue, alpha: &rightAlpha)
        return abs(leftRed - rightRed) < 0.01
            && abs(leftGreen - rightGreen) < 0.01
            && abs(leftBlue - rightBlue) < 0.01
            && abs(leftAlpha - rightAlpha) < 0.01
    }

    private func updateWindowSuggestion(at point: CGPoint) {
        guard allowsWindowSuggestions, activeTool == nil, !toolbarFrame.contains(point) else { return }
        guard let windowRect = windowCandidates.first(where: { $0.contains(point) }) else {
            if isWindowSuggestion {
                selection = .zero
                isWindowSuggestion = false
                refreshVisualOverlay()
            }
            return
        }

        if selection != windowRect || !isWindowSuggestion {
            selection = windowRect
            isWindowSuggestion = true
            refreshVisualOverlay()
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
        activeAnnotationEnd = point
        if tool == .pen {
            activePenPoints = [point]
        }
    }

    private func updateAnnotation(tool: AnnotationTool, at point: CGPoint) {
        activeAnnotationEnd = point
        if tool == .pen {
            activePenPoints.append(point)
        }
        refreshVisualOverlay()
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
        activeAnnotationEnd = nil
        dragMode = .none
        refreshVisualOverlay()
    }

    private var activeAnnotationPreview: AnnotationShape? {
        guard case .annotating(let tool) = dragMode,
              let dragStart,
              let activeAnnotationEnd
        else {
            return nil
        }

        switch tool {
        case .arrow:
            return .arrow(start: dragStart, end: activeAnnotationEnd, color: activeColor)
        case .rectangle:
            return .rectangle(CGRect.from(dragStart, activeAnnotationEnd), activeColor)
        case .text:
            return .text("文本", activeAnnotationEnd, activeColor)
        case .pen:
            return nil
        }
    }

    private func rebuildToolbar() {
        guard selection.width > 0, selection.height > 0 else { return }

        let buttonSize: CGFloat = 40
        let spacing: CGFloat = 4
        var buttons: [(String, String, ToolbarAction, AnnotationTool?, NSColor?)] = [
            ("xmark", "取消", .cancel, nil, nil),
            ("square.and.arrow.down", "保存", .save, nil, nil),
            ("text.viewfinder", "OCR", .ocr, nil, nil),
            ("character.book.closed", "翻译", .translate, nil, nil),
            (AnnotationTool.arrow.symbolName, "箭头", .tool(.arrow), .arrow, nil),
            (AnnotationTool.rectangle.symbolName, "矩形", .tool(.rectangle), .rectangle, nil),
            (AnnotationTool.pen.symbolName, "画笔", .tool(.pen), .pen, nil),
            ("checkmark", "完成", .copy, nil, nil)
        ]

        if activeTool != nil {
            buttons.insert(("circle.fill", "颜色", .pickColor, nil, activeColor), at: buttons.count - 1)
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
    case pickingHue
    case pickingBrightness
}

@MainActor
private final class CaptureVisualOverlay {
    private static var knownPanels: [WeakVisualPanel] = []
    private let dimPanels = (0..<4).map { _ in VisualPanel() }
    private let annotationPanel = VisualPanel()
    private let annotationView = AnnotationOverlayView()
    private let borderPanels = (0..<4).map { _ in VisualPanel() }
    private let handlePanels = (0..<8).map { _ in VisualPanel() }
    private let dimensionPanel = VisualPanel()
    private let dimensionView = DimensionOverlayView()
    private let toolbarPanel = VisualPanel()
    private let toolbarView = ToolbarOverlayView()
    private var screenFrame: CGRect = .zero
    private var isClosed = false
    var onMouseDown: ((CGPoint) -> Void)? {
        didSet { toolbarView.onMouseDown = onMouseDown }
    }
    var onMouseDragged: ((CGPoint) -> Void)? {
        didSet { toolbarView.onMouseDragged = onMouseDragged }
    }
    var onMouseUp: ((CGPoint) -> Void)? {
        didSet { toolbarView.onMouseUp = onMouseUp }
    }
    var onMouseMoved: ((CGPoint) -> Void)? {
        didSet { toolbarView.onMouseMoved = onMouseMoved }
    }

    init() {
        for panel in allPanels {
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
        }
        for panel in dimPanels {
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.42)
        }
        for panel in borderPanels {
            panel.backgroundColor = NSColor.systemBlue
        }
        for panel in handlePanels {
            let view = HandleOverlayView()
            panel.contentView = view
            panel.backgroundColor = NSColor.clear
        }
        annotationPanel.contentView = annotationView
        annotationPanel.backgroundColor = .clear
        dimensionPanel.contentView = dimensionView
        dimensionPanel.backgroundColor = .clear
        toolbarPanel.contentView = toolbarView
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.ignoresMouseEvents = false
        toolbarPanel.acceptsMouseMovedEvents = true
    }

    func show(screenFrame: CGRect, level: NSWindow.Level) {
        guard !isClosed else { return }
        self.screenFrame = screenFrame
        for panel in allPanels {
            panel.level = level
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        for panel in allPanels {
            panel.orderOut(nil)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        allPanels.forEach(Self.closePanel)
        Self.closeAllPanels()
    }

    static func register(_ panel: NSPanel) {
        knownPanels = knownPanels.filter { $0.panel != nil }
        knownPanels.append(WeakVisualPanel(panel))
    }

    static func closeAllPanels() {
        for item in knownPanels {
            if let panel = item.panel {
                closePanel(panel)
            }
        }
        knownPanels.removeAll()
    }

    private static func closePanel(_ panel: NSPanel) {
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
        panel.setFrame(.zero, display: false)
    }

    func update(
        screenFrame: CGRect,
        bounds: CGRect,
        selection: CGRect,
        scale: CGFloat,
        isWindowSuggestion: Bool,
        annotations: [AnnotationShape],
        activeAnnotationPreview: AnnotationShape?,
        activePenPoints: [CGPoint],
        toolbarFrame: CGRect,
        toolbarButtons: [ToolButton],
        hoveredToolbarButton: ToolButton?,
        activeTool: AnnotationTool?,
        activeColor: NSColor,
        activeHue: CGFloat,
        activeBrightness: CGFloat,
        colorPickerFrame: CGRect,
        colorHueSliderFrame: CGRect,
        colorBrightnessSliderFrame: CGRect,
        colorSwatchFrames: [(color: NSColor, frame: CGRect)],
        isColorPickerVisible: Bool,
        dimensionLabelFrame: CGRect,
        isDarkAppearance: Bool
    ) {
        guard !isClosed else { return }
        self.screenFrame = screenFrame
        updateDimming(bounds: bounds, selection: selection)
        updateAnnotations(
            bounds: bounds,
            selection: selection,
            annotations: annotations,
            activeAnnotationPreview: activeAnnotationPreview,
            activePenPoints: activePenPoints,
            activeColor: activeColor
        )
        updateSelectionChrome(selection: selection)
        updateDimension(frame: dimensionLabelFrame, text: "\(Int(selection.width * scale)) × \(Int(selection.height * scale))")
        updateToolbar(
            toolbarFrame: toolbarFrame,
            toolbarButtons: toolbarButtons,
            hoveredToolbarButton: hoveredToolbarButton,
            activeTool: activeTool,
            activeColor: activeColor,
            activeHue: activeHue,
            activeBrightness: activeBrightness,
            colorPickerFrame: colorPickerFrame,
            colorHueSliderFrame: colorHueSliderFrame,
            colorBrightnessSliderFrame: colorBrightnessSliderFrame,
            colorSwatchFrames: colorSwatchFrames,
            isColorPickerVisible: isColorPickerVisible,
            isHidden: selection.width <= 0 || selection.height <= 0 || isWindowSuggestion,
            isDarkAppearance: isDarkAppearance
        )
    }

    private var allPanels: [VisualPanel] {
        dimPanels + [annotationPanel] + borderPanels + handlePanels + [dimensionPanel, toolbarPanel]
    }

    private func updateDimming(bounds: CGRect, selection rawSelection: CGRect) {
        let selection = rawSelection.standardized.intersection(bounds)
        let rects: [CGRect]
        if selection.width > 0, selection.height > 0 {
            rects = [
                CGRect(x: bounds.minX, y: selection.maxY, width: bounds.width, height: max(0, bounds.maxY - selection.maxY)),
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, selection.minY - bounds.minY)),
                CGRect(x: bounds.minX, y: selection.minY, width: max(0, selection.minX - bounds.minX), height: selection.height),
                CGRect(x: selection.maxX, y: selection.minY, width: max(0, bounds.maxX - selection.maxX), height: selection.height)
            ]
        } else {
            rects = [bounds, .zero, .zero, .zero]
        }

        for (panel, rect) in zip(dimPanels, rects) {
            setPanel(panel, localFrame: rect)
        }
    }

    private func updateAnnotations(
        bounds: CGRect,
        selection rawSelection: CGRect,
        annotations: [AnnotationShape],
        activeAnnotationPreview: AnnotationShape?,
        activePenPoints: [CGPoint],
        activeColor: NSColor
    ) {
        let selection = rawSelection.standardized.intersection(bounds)
        let hasPreview = activeAnnotationPreview != nil || activePenPoints.count > 1
        guard selection.width > 0,
              selection.height > 0,
              !annotations.isEmpty || hasPreview,
              let annotationBounds = Self.annotationBounds(
                annotations: annotations,
                activeAnnotationPreview: activeAnnotationPreview,
                activePenPoints: activePenPoints
              )
        else {
            annotationView.state = nil
            annotationPanel.orderOut(nil)
            return
        }

        let frame = annotationBounds
            .standardized
            .insetBy(dx: -28, dy: -28)
            .intersection(selection)
            .integral
        guard frame.width > 0, frame.height > 0 else {
            annotationView.state = nil
            annotationPanel.orderOut(nil)
            return
        }

        annotationView.state = AnnotationOverlayState(
            panelOrigin: frame.origin,
            annotations: annotations,
            activeAnnotationPreview: activeAnnotationPreview,
            activePenPoints: activePenPoints,
            activePenColor: activeColor
        )
        setPanel(annotationPanel, localFrame: frame)
        annotationView.frame = CGRect(origin: .zero, size: frame.size)
        annotationView.needsDisplay = true
    }

    private static func annotationBounds(
        annotations: [AnnotationShape],
        activeAnnotationPreview: AnnotationShape?,
        activePenPoints: [CGPoint]
    ) -> CGRect? {
        var bounds: CGRect?
        for annotation in annotations {
            bounds = union(bounds, shapeBounds(annotation))
        }
        if let activeAnnotationPreview {
            bounds = union(bounds, shapeBounds(activeAnnotationPreview))
        }
        if let penBounds = pointBounds(activePenPoints) {
            bounds = union(bounds, penBounds)
        }
        return bounds
    }

    private static func shapeBounds(_ annotation: AnnotationShape) -> CGRect {
        switch annotation {
        case let .arrow(start, end, _):
            return CGRect.from(start, end)
        case let .rectangle(rect, _):
            return rect.standardized
        case let .text(text, point, _):
            let size = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold)])
            return CGRect(origin: point, size: size)
        case let .pen(points, _):
            return pointBounds(points) ?? .zero
        }
    }

    private static func pointBounds(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func union(_ current: CGRect?, _ next: CGRect) -> CGRect {
        guard let current else { return next }
        return current.union(next)
    }

    private func updateSelectionChrome(selection rawSelection: CGRect) {
        let selection = rawSelection.standardized
        guard selection.width > 0, selection.height > 0 else {
            for panel in borderPanels + handlePanels {
                panel.orderOut(nil as Any?)
            }
            return
        }

        let line: CGFloat = 2
        let borderRects = [
            CGRect(x: selection.minX, y: selection.maxY - line, width: selection.width, height: line),
            CGRect(x: selection.minX, y: selection.minY, width: selection.width, height: line),
            CGRect(x: selection.minX, y: selection.minY, width: line, height: selection.height),
            CGRect(x: selection.maxX - line, y: selection.minY, width: line, height: selection.height)
        ]
        for (panel, rect) in zip(borderPanels, borderRects) {
            setPanel(panel, localFrame: rect)
        }

        let handleSize: CGFloat = 10
        for (panel, point) in zip(handlePanels, selection.handlePoints) {
            setPanel(
                panel,
                localFrame: CGRect(
                    x: point.x - handleSize / 2,
                    y: point.y - handleSize / 2,
                    width: handleSize,
                    height: handleSize
                )
            )
        }
    }

    private func updateDimension(frame: CGRect, text: String) {
        guard frame.width > 0, frame.height > 0 else {
            dimensionPanel.orderOut(nil)
            return
        }
        dimensionView.text = text
        setPanel(dimensionPanel, localFrame: frame)
        dimensionView.frame = CGRect(origin: .zero, size: frame.size)
        dimensionView.needsDisplay = true
    }

    private func updateToolbar(
        toolbarFrame: CGRect,
        toolbarButtons: [ToolButton],
        hoveredToolbarButton: ToolButton?,
        activeTool: AnnotationTool?,
        activeColor: NSColor,
        activeHue: CGFloat,
        activeBrightness: CGFloat,
        colorPickerFrame: CGRect,
        colorHueSliderFrame: CGRect,
        colorBrightnessSliderFrame: CGRect,
        colorSwatchFrames: [(color: NSColor, frame: CGRect)],
        isColorPickerVisible: Bool,
        isHidden: Bool,
        isDarkAppearance: Bool
    ) {
        guard !isHidden, toolbarFrame.width > 0, toolbarFrame.height > 0 else {
            toolbarPanel.orderOut(nil)
            return
        }

        var frame = toolbarFrame
        if isColorPickerVisible {
            frame = frame.union(colorPickerFrame)
        }
        if let hoveredToolbarButton {
            frame = frame.union(ToolbarOverlayView.tooltipFrame(
                for: hoveredToolbarButton,
                toolbarFrame: toolbarFrame,
                bounds: CGRect(origin: .zero, size: screenFrame.size)
            ))
        }
        frame = frame.insetBy(dx: -4, dy: -4)

        toolbarView.state = ToolbarOverlayState(
            panelOrigin: frame.origin,
            bounds: CGRect(origin: .zero, size: screenFrame.size),
            toolbarFrame: toolbarFrame,
            toolbarButtons: toolbarButtons,
            hoveredToolbarButton: hoveredToolbarButton,
            activeTool: activeTool,
            activeColor: activeColor,
            activeHue: activeHue,
            activeBrightness: activeBrightness,
            colorPickerFrame: colorPickerFrame,
            colorHueSliderFrame: colorHueSliderFrame,
            colorBrightnessSliderFrame: colorBrightnessSliderFrame,
            colorSwatchFrames: colorSwatchFrames,
            isColorPickerVisible: isColorPickerVisible,
            isDarkAppearance: isDarkAppearance
        )
        setPanel(toolbarPanel, localFrame: frame)
        toolbarView.frame = CGRect(origin: .zero, size: frame.size)
        toolbarView.needsDisplay = true
    }

    private func setPanel(_ panel: NSPanel, localFrame: CGRect) {
        let frame = localFrame.standardized
        guard frame.width > 0, frame.height > 0 else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(
            CGRect(
                x: screenFrame.minX + frame.minX,
                y: screenFrame.minY + frame.minY,
                width: frame.width,
                height: frame.height
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }
}

private final class VisualPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        CaptureVisualOverlay.register(self)
    }
}

private final class WeakVisualPanel {
    weak var panel: NSPanel?

    init(_ panel: NSPanel) {
        self.panel = panel
    }
}

private final class HandleOverlayView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor(calibratedWhite: 0.08, alpha: 0.58).setStroke()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).stroke()
    }
}

private final class DimensionOverlayView: NSView {
    var text: String = ""

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.09, alpha: 0.78).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: CGPoint(x: bounds.minX + 9, y: bounds.minY + 6),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
    }
}

private struct AnnotationOverlayState {
    let panelOrigin: CGPoint
    let annotations: [AnnotationShape]
    let activeAnnotationPreview: AnnotationShape?
    let activePenPoints: [CGPoint]
    let activePenColor: NSColor
}

private final class AnnotationOverlayView: NSView {
    var state: AnnotationOverlayState?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: -state.panelOrigin.x, yBy: -state.panelOrigin.y)
        transform.concat()

        for annotation in state.annotations {
            draw(annotation)
        }
        if let activeAnnotationPreview = state.activeAnnotationPreview {
            draw(activeAnnotationPreview)
        }
        drawPen(points: state.activePenPoints, color: state.activePenColor)

        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ annotation: AnnotationShape) {
        switch annotation {
        case let .arrow(start, end, color):
            drawArrow(start: start, end: end, color: color)
        case let .rectangle(rect, color):
            color.setStroke()
            let path = NSBezierPath(rect: rect.standardized)
            path.lineWidth = 3
            path.stroke()
        case let .text(text, point, color):
            text.draw(
                at: point,
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                    .foregroundColor: color
                ]
            )
        case let .pen(points, color):
            drawPen(points: points, color: color)
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

    private func drawPen(points: [CGPoint], color: NSColor? = nil) {
        guard points.count > 1 else { return }
        if let color {
            color.setStroke()
        }
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

private struct ToolbarOverlayState {
    let panelOrigin: CGPoint
    let bounds: CGRect
    let toolbarFrame: CGRect
    let toolbarButtons: [ToolButton]
    let hoveredToolbarButton: ToolButton?
    let activeTool: AnnotationTool?
    let activeColor: NSColor
    let activeHue: CGFloat
    let activeBrightness: CGFloat
    let colorPickerFrame: CGRect
    let colorHueSliderFrame: CGRect
    let colorBrightnessSliderFrame: CGRect
    let colorSwatchFrames: [(color: NSColor, frame: CGRect)]
    let isColorPickerVisible: Bool
    let isDarkAppearance: Bool
}

private final class ToolbarOverlayView: NSView {
    var state: ToolbarOverlayState?
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?

    override var isOpaque: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let point = localPoint(from: event) else { return }
        onMouseDown?(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = localPoint(from: event) else { return }
        onMouseDragged?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let point = localPoint(from: event) else { return }
        onMouseUp?(point)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let point = localPoint(from: event) else { return }
        onMouseMoved?(point)
    }

    private func localPoint(from event: NSEvent) -> CGPoint? {
        guard let state else { return nil }
        let windowPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: windowPoint.x + state.panelOrigin.x,
            y: windowPoint.y + state.panelOrigin.y
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: -state.panelOrigin.x, yBy: -state.panelOrigin.y)
        transform.concat()
        drawToolbar(state)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func tooltipFrame(for button: ToolButton, toolbarFrame: CGRect, bounds: CGRect) -> CGRect {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let textSize = button.title.size(withAttributes: attributes)
        let tooltipSize = CGSize(width: textSize.width + 18, height: 28)
        let x = min(max(button.frame.midX - tooltipSize.width / 2, bounds.minX + 8), bounds.maxX - tooltipSize.width - 8)
        let y: CGFloat
        if toolbarFrame.maxY + tooltipSize.height + 8 <= bounds.maxY {
            y = toolbarFrame.maxY + 6
        } else {
            y = toolbarFrame.minY - tooltipSize.height - 6
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: tooltipSize)
    }

    private func drawToolbar(_ state: ToolbarOverlayState) {
        toolbarBackgroundColor(isDark: state.isDarkAppearance).setFill()
        NSBezierPath(roundedRect: state.toolbarFrame, xRadius: 8, yRadius: 8).fill()

        for button in state.toolbarButtons {
            let isActive = button.tool == state.activeTool && button.tool != nil
            if isActive {
                NSColor.systemBlue.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: button.frame.insetBy(dx: 3, dy: 4), xRadius: 6, yRadius: 6).fill()
            }

            if let color = button.color {
                color.setFill()
                NSBezierPath(ovalIn: button.frame.insetBy(dx: 10, dy: 10)).fill()
                toolbarColorStroke(isDark: state.isDarkAppearance).setStroke()
                NSBezierPath(ovalIn: button.frame.insetBy(dx: 10, dy: 10)).stroke()
            } else if let image = NSImage(systemSymbolName: button.symbolName, accessibilityDescription: button.title) {
                let tint = isActive ? NSColor.white : toolbarIconColor(isDark: state.isDarkAppearance)
                image.tinted(with: tint).draw(in: button.frame.insetBy(dx: 11, dy: 11))
            }
        }

        if state.isColorPickerVisible {
            drawColorPicker(state)
        } else if let hovered = state.hoveredToolbarButton {
            drawTooltip(for: hovered, state: state)
        }
    }

    private func drawTooltip(for button: ToolButton, state: ToolbarOverlayState) {
        let tooltipFrame = Self.tooltipFrame(for: button, toolbarFrame: state.toolbarFrame, bounds: state.bounds)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: tooltipTextColor(isDark: state.isDarkAppearance)
        ]
        tooltipBackgroundColor(isDark: state.isDarkAppearance).setFill()
        NSBezierPath(roundedRect: tooltipFrame, xRadius: 6, yRadius: 6).fill()
        toolbarColorStroke(isDark: state.isDarkAppearance).setStroke()
        let border = NSBezierPath(roundedRect: tooltipFrame, xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()
        button.title.draw(at: CGPoint(x: tooltipFrame.minX + 9, y: tooltipFrame.minY + 7), withAttributes: attributes)
    }

    private func drawColorPicker(_ state: ToolbarOverlayState) {
        colorPickerBackgroundColor(isDark: state.isDarkAppearance).setFill()
        NSBezierPath(roundedRect: state.colorPickerFrame, xRadius: 8, yRadius: 8).fill()
        toolbarColorStroke(isDark: state.isDarkAppearance).setStroke()
        let border = NSBezierPath(roundedRect: state.colorPickerFrame, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        for item in state.colorSwatchFrames {
            item.color.setFill()
            NSBezierPath(ovalIn: item.frame).fill()
            (isSameColor(item.color, state.activeColor) ? NSColor.systemBlue : toolbarColorStroke(isDark: state.isDarkAppearance)).setStroke()
            let swatchBorder = NSBezierPath(ovalIn: item.frame.insetBy(dx: -2, dy: -2))
            swatchBorder.lineWidth = isSameColor(item.color, state.activeColor) ? 2 : 1
            swatchBorder.stroke()
        }

        drawHueSlider(state)
        drawBrightnessSlider(state)
    }

    private func drawHueSlider(_ state: ToolbarOverlayState) {
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemCyan, .systemBlue, .systemPurple, .systemRed]
        NSGradient(colors: colors)?.draw(in: state.colorHueSliderFrame, angle: 0)
        drawSliderBorder(state.colorHueSliderFrame, isDark: state.isDarkAppearance)
        drawSliderIndicator(at: state.colorHueSliderFrame.minX + state.activeHue * state.colorHueSliderFrame.width, in: state.colorHueSliderFrame)
    }

    private func drawBrightnessSlider(_ state: ToolbarOverlayState) {
        let brightColor = NSColor(calibratedHue: state.activeHue, saturation: 0.85, brightness: 1, alpha: 1)
        NSGradient(colors: [.black, brightColor])?.draw(in: state.colorBrightnessSliderFrame, angle: 0)
        drawSliderBorder(state.colorBrightnessSliderFrame, isDark: state.isDarkAppearance)
        drawSliderIndicator(at: state.colorBrightnessSliderFrame.minX + state.activeBrightness * state.colorBrightnessSliderFrame.width, in: state.colorBrightnessSliderFrame)
    }

    private func drawSliderBorder(_ frame: CGRect, isDark: Bool) {
        toolbarColorStroke(isDark: isDark).setStroke()
        let border = NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        border.stroke()
    }

    private func drawSliderIndicator(at x: CGFloat, in frame: CGRect) {
        let indicatorFrame = CGRect(x: x - 2, y: frame.minY - 3, width: 4, height: frame.height + 6)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: indicatorFrame, xRadius: 2, yRadius: 2).fill()
        NSColor.black.withAlphaComponent(0.72).setStroke()
        let border = NSBezierPath(roundedRect: indicatorFrame, xRadius: 2, yRadius: 2)
        border.lineWidth = 1
        border.stroke()
    }

    private func toolbarBackgroundColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedWhite: 0.08, alpha: 0.82) : NSColor.white.withAlphaComponent(0.92)
    }

    private func toolbarIconColor(isDark: Bool) -> NSColor {
        isDark ? .white.withAlphaComponent(0.92) : .black.withAlphaComponent(0.86)
    }

    private func toolbarColorStroke(isDark: Bool) -> NSColor {
        isDark ? .white.withAlphaComponent(0.85) : .black.withAlphaComponent(0.55)
    }

    private func tooltipBackgroundColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedWhite: 0.10, alpha: 0.92) : NSColor.white.withAlphaComponent(0.96)
    }

    private func tooltipTextColor(isDark: Bool) -> NSColor {
        isDark ? .white.withAlphaComponent(0.95) : .black.withAlphaComponent(0.88)
    }

    private func colorPickerBackgroundColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(calibratedWhite: 0.08, alpha: 0.94) : NSColor.white.withAlphaComponent(0.97)
    }

    private func isSameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let left = lhs.usingColorSpace(.deviceRGB) ?? lhs
        let right = rhs.usingColorSpace(.deviceRGB) ?? rhs
        var leftRed: CGFloat = 0
        var leftGreen: CGFloat = 0
        var leftBlue: CGFloat = 0
        var leftAlpha: CGFloat = 0
        var rightRed: CGFloat = 0
        var rightGreen: CGFloat = 0
        var rightBlue: CGFloat = 0
        var rightAlpha: CGFloat = 0
        left.getRed(&leftRed, green: &leftGreen, blue: &leftBlue, alpha: &leftAlpha)
        right.getRed(&rightRed, green: &rightGreen, blue: &rightBlue, alpha: &rightAlpha)
        return abs(leftRed - rightRed) < 0.01
            && abs(leftGreen - rightGreen) < 0.01
            && abs(leftBlue - rightBlue) < 0.01
            && abs(leftAlpha - rightAlpha) < 0.01
    }
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

    var isColorPicker: Bool {
        if case .pickColor = self {
            return true
        }
        return false
    }
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
        let rawBounds = CGDisplayBounds(snapshot.displayID)
        let scale = coordinateScale(rawDisplayBounds: rawBounds, snapshot: snapshot)
        guard scale > 0 else { return rawBounds }
        return rawBounds.scaled(by: 1 / scale)
    }

    private static func normalizedWindowBounds(_ rawBounds: CGRect, snapshot: ScreenSnapshot) -> CGRect {
        let rawDisplayBounds = CGDisplayBounds(snapshot.displayID)
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
