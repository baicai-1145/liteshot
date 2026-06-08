import AppKit

@MainActor
final class CaptureCoordinator {
    private let snapshot: ScreenSnapshot
    private let mode: CaptureMode
    private let settings: AppSettings
    private let historyStore: CaptureHistoryStore
    private let ocrService: OCRService
    private let translationService: OpenAITranslationService
    private var panel: NSPanel?
    private var completion: (() -> Void)?

    init(
        snapshot: ScreenSnapshot,
        mode: CaptureMode,
        settings: AppSettings,
        historyStore: CaptureHistoryStore,
        ocrService: OCRService,
        translationService: OpenAITranslationService
    ) {
        self.snapshot = snapshot
        self.mode = mode
        self.settings = settings
        self.historyStore = historyStore
        self.ocrService = ocrService
        self.translationService = translationService
    }

    func start(onFinish: @escaping () -> Void) {
        completion = onFinish
        let panel = CapturePanel(screenFrame: snapshot.screenFrame)
        let view = CaptureOverlayView(snapshot: snapshot, initialMode: mode)
        view.delegate = self
        panel.contentView = view
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.orderFrontRegardless()
            panel.makeKey()
        }

        if mode == .fullScreen {
            view.selectFullScreen()
        }
    }

    private func finish() {
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.orderOut(nil)
            }
        }
        panel = nil
        completion?()
    }

    private func renderCurrentSelection(from view: CaptureOverlayView) -> NSImage? {
        guard let image = view.renderSelection() else {
            AlertPresenter.show("请选择截图区域。")
            return nil
        }
        return image
    }

    private func saveCurrentSelection(from view: CaptureOverlayView) -> SavedCapture? {
        guard let image = renderCurrentSelection(from: view) else { return nil }

        if settings.copyToClipboard {
            PasteboardWriter.copy(image: image)
        }

        do {
            let directory = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
            let url = try ImageExporter.write(image, format: settings.imageFormat, directory: directory)
            if settings.playSound {
                NSSound(named: "Glass")?.play()
            }
            let historyID = historyStore.add(imageURL: url, pixelSize: image.pixelSize)
            return SavedCapture(image: image, url: url, historyID: historyID)
        } catch {
            AlertPresenter.show(error.localizedDescription)
            return nil
        }
    }
}

extension CaptureCoordinator: CaptureOverlayViewDelegate {
    func captureOverlayDidCancel(_ view: CaptureOverlayView) {
        finish()
    }

    func captureOverlayDidRequestCopy(_ view: CaptureOverlayView) {
        guard let image = renderCurrentSelection(from: view) else { return }
        PasteboardWriter.copy(image: image)
        NSSound(named: "Pop")?.play()
        finish()
    }

    func captureOverlayDidRequestSave(_ view: CaptureOverlayView) {
        _ = saveCurrentSelection(from: view)
        finish()
    }

    func captureOverlayDidRequestOCR(_ view: CaptureOverlayView) {
        guard let image = renderCurrentSelection(from: view) else { return }
        Task { @MainActor in
            do {
                let text = try await ocrService.recognizeText(in: image)
                PasteboardWriter.copy(text: text)
                OCRResultWindowController.show(image: image, text: text)
            } catch {
                AlertPresenter.show(error.localizedDescription)
            }
        }
        finish()
    }

    func captureOverlayDidRequestTranslate(_ view: CaptureOverlayView) {
        guard let image = renderCurrentSelection(from: view) else { return }
        let resultWindow = OCRResultWindowController.showLoading(image: image, title: "翻译结果", status: "正在识别文字...")
        finish()

        Task { @MainActor in
            do {
                let lines = try await ocrService.recognizeTextLines(in: image)
                guard !lines.isEmpty else {
                    resultWindow.updateStatus("未识别到可翻译文字。")
                    return
                }
                resultWindow.updateStatus("已识别 \(lines.count) 行文字，正在翻译...")
                let translatedLines = try await translationService.translateLines(lines) { completed, total in
                    resultWindow.updateStatus("正在翻译 \(completed)/\(total)...")
                }
                let translatedText = translatedLines.map(\.translatedText).joined(separator: "\n")
                resultWindow.updateStatus("正在嵌入翻译结果...")
                let translatedImage = EmbeddedTranslationRenderer.render(image: image, lines: translatedLines)
                PasteboardWriter.copy(text: translatedText)
                resultWindow.update(image: translatedImage, text: translatedText, title: "翻译结果")
            } catch {
                resultWindow.updateStatus("翻译失败：\(error.localizedDescription)")
            }
        }
    }
}

private struct SavedCapture {
    let image: NSImage
    let url: URL?
    let historyID: UUID?
}

private extension NSImage {
    var pixelSize: CGSize {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return size
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}
