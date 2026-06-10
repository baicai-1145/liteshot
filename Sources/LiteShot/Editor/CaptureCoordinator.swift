import AppKit

@MainActor
final class CaptureCoordinator {
    private let snapshots: [ScreenSnapshot]
    private let mode: CaptureMode
    private let settings: AppSettings
    private let historyStore: CaptureHistoryStore
    private let ocrService: OCRService
    private let translationService: OpenAITranslationService
    private var panels: [NSPanel] = []
    private var completion: (() -> Void)?

    init(
        snapshots: [ScreenSnapshot],
        mode: CaptureMode,
        settings: AppSettings,
        historyStore: CaptureHistoryStore,
        ocrService: OCRService,
        translationService: OpenAITranslationService
    ) {
        self.snapshots = snapshots
        self.mode = mode
        self.settings = settings
        self.historyStore = historyStore
        self.ocrService = ocrService
        self.translationService = translationService
    }

    func start(onFinish: @escaping () -> Void) {
        completion = onFinish
        var createdPanels: [NSPanel] = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            for snapshot in snapshots {
                let panel = CapturePanel(screenFrame: snapshot.screenFrame)
                let view = CaptureOverlayView(snapshot: snapshot, initialMode: mode)
                view.delegate = self
                panel.contentView = view
                panel.orderFrontRegardless()
                createdPanels.append(panel)

                if mode == .fullScreen {
                    view.selectFullScreen()
                }
            }
        }
        panels = createdPanels

        let mouseLocation = NSEvent.mouseLocation
        let keyPanel = panels.first { $0.frame.contains(mouseLocation) } ?? panels.first
        keyPanel?.makeKey()
    }

    private func finish() {
        for panel in panels {
            (panel.contentView as? CaptureOverlayView)?.closeVisualOverlay()
            panel.contentView = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.orderOut(nil)
            }
            panel.close()
        }
        CaptureOverlayView.closeAllVisualOverlays()
        panels.removeAll()
        let completion = completion
        self.completion = nil
        completion?()
        DispatchQueue.main.async {
            CaptureOverlayView.closeAllVisualOverlays()
        }
        MemoryPressureRelief.releaseAfterCurrentEvent()
    }

    private func renderCurrentSelection(from view: CaptureOverlayView) -> CapturedImage? {
        guard view.canRenderSelection() else {
            AlertPresenter.show("请选择截图区域。")
            return nil
        }

        finish()
        releasePanelBackingBeforeRendering()
        guard let image = view.renderSelection(overlayIsAlreadyClosed: true) else {
            AlertPresenter.show("截图失败。")
            return nil
        }
        return image
    }

    func renderSelectionForMemorySmoke() -> CapturedImage? {
        guard let view = firstOverlayViewForMemorySmoke() else { return nil }
        guard view.canRenderSelection() else { return nil }
        finish()
        releasePanelBackingBeforeRendering()
        return view.renderSelection(overlayIsAlreadyClosed: true)
    }

    func finishMemorySmoke() {
        finish()
    }

    func triggerToolbarCompletionForMemorySmoke() -> Bool {
        guard let view = firstOverlayViewForMemorySmoke() else { return false }
        return view.triggerToolbarCompletionForMemorySmoke()
    }

    func showAnnotationPreviewForMemorySmoke() -> Bool {
        guard let view = firstOverlayViewForMemorySmoke() else { return false }
        return view.showAnnotationPreviewForMemorySmoke()
    }

    private func firstOverlayViewForMemorySmoke() -> CaptureOverlayView? {
        panels.compactMap { $0.contentView as? CaptureOverlayView }.first
    }

    private func releasePanelBackingBeforeRendering() {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        MemoryPressureRelief.releaseNow()
    }

    private func saveCurrentSelection(from view: CaptureOverlayView) {
        guard let image = renderCurrentSelection(from: view) else { return }

        if settings.copyToClipboard {
            PasteboardWriter.copy(image)
        }

        do {
            let directory = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
            let url = try ImageExporter.write(image, format: settings.imageFormat, directory: directory)
            if settings.playSound {
                NSSound(named: "Glass")?.play()
            }
            historyStore.add(imageURL: url, pixelSize: image.pixelSize)
        } catch {
            AlertPresenter.show(error.localizedDescription)
        }
        MemoryPressureRelief.releaseAfterCurrentEvent()
    }
}

extension CaptureCoordinator: CaptureOverlayViewDelegate {
    func captureOverlayDidCancel(_ view: CaptureOverlayView) {
        finish()
    }

    func captureOverlayDidRequestCopy(_ view: CaptureOverlayView) {
        guard let image = renderCurrentSelection(from: view) else { return }
        PasteboardWriter.copy(image)
        NSSound(named: "Pop")?.play()
        MemoryPressureRelief.releaseAfterCurrentEvent()
    }

    func captureOverlayDidRequestSave(_ view: CaptureOverlayView) {
        saveCurrentSelection(from: view)
    }

    func captureOverlayDidRequestOCR(_ view: CaptureOverlayView) {
        guard let image = renderCurrentSelection(from: view) else { return }
        let ocrService = ocrService
        Task { @MainActor [image, ocrService] in
            do {
                let text = try await ocrService.recognizeText(in: image)
                PasteboardWriter.copy(text: text)
                OCRResultWindowController.show(image: image.nsImage, text: text)
            } catch {
                AlertPresenter.show(error.localizedDescription)
            }
        }
    }

    func captureOverlayDidRequestTranslate(_ view: CaptureOverlayView) {
        guard let image = renderCurrentSelection(from: view) else { return }
        let resultWindow = OCRResultWindowController.showLoading(image: image.nsImage, title: "翻译结果", status: "正在识别文字...")
        let ocrService = ocrService
        let translationService = translationService

        Task { @MainActor [image, ocrService, resultWindow, translationService] in
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
                resultWindow.update(image: translatedImage.nsImage, text: translatedText, title: "翻译结果")
            } catch {
                resultWindow.updateStatus("翻译失败：\(error.localizedDescription)")
            }
        }
    }
}

private extension NSImage {
    var pixelSize: CGSize {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return size
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}
