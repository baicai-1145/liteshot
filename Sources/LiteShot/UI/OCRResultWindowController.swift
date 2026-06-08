import AppKit
import UniformTypeIdentifiers

@MainActor
final class OCRResultWindowController: NSObject, NSWindowDelegate {
    private static var activeControllers: [OCRResultWindowController] = []

    private let window: NSWindow
    private let contentView: OCRResultContentView

    static func show(image: NSImage, text: String, title: String = "OCR 结果") {
        let controller = OCRResultWindowController(image: image, text: text, title: title)
        controller.show()
    }

    @discardableResult
    static func showLoading(image: NSImage, title: String, status: String) -> OCRResultWindowController {
        let controller = OCRResultWindowController(image: image, text: status, title: title)
        controller.show()
        return controller
    }

    private init(image: NSImage, text: String, title: String) {
        contentView = OCRResultContentView(image: image, text: text)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.center()
        super.init()
        window.delegate = self
    }

    func update(image: NSImage, text: String, title: String? = nil) {
        if let title {
            window.title = title
        }
        contentView.update(image: image, text: text)
    }

    func updateStatus(_ status: String) {
        contentView.updateText(status)
    }

    private func show() {
        Self.activeControllers.append(self)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        Self.activeControllers.removeAll { $0 === self }
    }
}

private final class OCRResultContentView: NSView {
    private var image: NSImage
    private var recognizedText: String
    private let previewContainer = NSView()
    private let imageView = NSImageView()
    private let rightPanel = NSView()
    private let textView = NSTextView()
    private let bottomBar = NSView()
    private let zoomLabel = NSTextField(labelWithString: "适合")
    private var imageWidthConstraint: NSLayoutConstraint?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var zoomScale: CGFloat = 1
    private var isFitMode = true

    init(image: NSImage, text: String) {
        self.image = image
        self.recognizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1).cgColor
        buildLayout()
        updateImageFrame()
    }

    func update(image: NSImage, text: String) {
        self.image = image
        imageView.image = image
        imageWidthConstraint?.constant = max(image.size.width, 1)
        imageHeightConstraint?.constant = max(image.size.height, 1)
        updateText(text)
        fitToWindow()
    }

    func updateText(_ text: String) {
        recognizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        textView.string = recognizedText.isEmpty ? "未识别到文字。" : recognizedText
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if isFitMode {
            updateImageFrame()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.fitToWindow()
        }
    }

    private func buildLayout() {
        addSubview(previewContainer)
        addSubview(rightPanel)
        addSubview(bottomBar)

        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            rightPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightPanel.widthAnchor.constraint(equalToConstant: 320),

            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 64),

            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            previewContainer.topAnchor.constraint(equalTo: topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: bottomBar.topAnchor)
        ])

        configurePreview()
        configureRightPanel()
        configureBottomBar()
    }

    private func configurePreview() {
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
        previewContainer.layer?.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.24).cgColor

        let width = imageView.widthAnchor.constraint(equalToConstant: max(image.size.width, 1))
        let height = imageView.heightAnchor.constraint(equalToConstant: max(image.size.height, 1))
        imageWidthConstraint = width
        imageHeightConstraint = height

        previewContainer.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            width,
            height
        ])
    }

    private func configureRightPanel() {
        rightPanel.wantsLayer = true
        rightPanel.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 1).cgColor

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(divider)

        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.addSubview(footer)

        let footerDivider = NSView()
        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerDivider)

        let copyButton = makeTextButton(title: "一键复制", symbolName: "doc.on.doc") { [weak self] in
            guard let self else { return }
            PasteboardWriter.copy(text: recognizedText)
        }
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(copyButton)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        rightPanel.addSubview(scrollView)

        textView.string = recognizedText.isEmpty ? "未识别到文字。" : recognizedText
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white.withAlphaComponent(0.9)
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            divider.topAnchor.constraint(equalTo: rightPanel.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: rightPanel.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 58),

            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            copyButton.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            copyButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            copyButton.heightAnchor.constraint(equalToConstant: 32),

            scrollView.leadingAnchor.constraint(equalTo: rightPanel.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: rightPanel.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: rightPanel.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8)
        ])
    }

    private func configureBottomBar() {
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor

        let topDivider = NSView()
        topDivider.wantsLayer = true
        topDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(topDivider)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(controls)

        controls.addArrangedSubview(makeIconButton(symbolName: "minus.magnifyingglass", accessibilityLabel: "缩小") { [weak self] in
            self?.setZoom((self?.zoomScale ?? 1) / 1.2)
        })

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        zoomLabel.textColor = .white.withAlphaComponent(0.86)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        controls.addArrangedSubview(zoomLabel)

        controls.addArrangedSubview(makeIconButton(symbolName: "plus.magnifyingglass", accessibilityLabel: "放大") { [weak self] in
            self?.setZoom((self?.zoomScale ?? 1) * 1.2)
        })

        controls.addArrangedSubview(makeIconButton(symbolName: "1.magnifyingglass", accessibilityLabel: "实际大小") { [weak self] in
            self?.setZoom(1)
        })

        controls.addArrangedSubview(separatorView())

        controls.addArrangedSubview(makeIconButton(symbolName: "arrow.up.left.and.arrow.down.right", accessibilityLabel: "适合窗口") { [weak self] in
            self?.fitToWindow()
        })

        controls.addArrangedSubview(makeIconButton(symbolName: "doc.on.doc", accessibilityLabel: "复制识别结果") { [weak self] in
            guard let self else { return }
            PasteboardWriter.copy(text: recognizedText)
        })

        controls.addArrangedSubview(makeIconButton(symbolName: "square.and.arrow.down", accessibilityLabel: "保存图片") { [weak self] in
            self?.saveImage()
        })

        NSLayoutConstraint.activate([
            topDivider.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 1),

            controls.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor)
        ])
    }

    private func updateImageFrame() {
        guard previewContainer.bounds.width > 0, previewContainer.bounds.height > 0 else { return }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let available = previewContainer.bounds.insetBy(dx: 40, dy: 40).size
        let fitScale = min(available.width / size.width, available.height / size.height)
        zoomScale = min(max(fitScale, 0.1), 1)
        applyZoom()
        zoomLabel.stringValue = "适合"
    }

    private func fitToWindow() {
        isFitMode = true
        updateImageFrame()
    }

    private func setZoom(_ scale: CGFloat) {
        isFitMode = false
        zoomScale = min(max(scale, 0.1), 6)
        applyZoom()
        zoomLabel.stringValue = "\(Int((zoomScale * 100).rounded()))%"
    }

    private func applyZoom() {
        let scaledSize = NSSize(width: image.size.width * zoomScale, height: image.size.height * zoomScale)
        imageWidthConstraint?.constant = max(scaledSize.width, 1)
        imageHeightConstraint?.constant = max(scaledSize.height, 1)
        imageView.needsDisplay = true
        previewContainer.needsLayout = true
    }

    private func saveImage() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OCR 截图.png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = ImageExporter.encodedData(for: image, format: .png) else {
                throw ExportError.encodingFailed
            }
            try data.write(to: url, options: [.atomic])
        } catch {
            AlertPresenter.show(error.localizedDescription)
        }
    }

    private func makeIconButton(symbolName: String, accessibilityLabel: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.image?.isTemplate = true
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.contentTintColor = .white.withAlphaComponent(0.88)
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    private func makeTextButton(title: String, symbolName: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action: action)
        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel(title)
        return button
    }

    private func separatorView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }
}

private final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        self.handler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(run)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
