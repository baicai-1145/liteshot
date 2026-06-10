import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let memorySmokeMode: Bool
    private let memorySmokeCopiesImage: Bool
    private let memorySmokeToolbarCompletion: Bool
    private let memorySmokeAnnotationPreview: Bool
    private let memorySmokeHoldOverlay: Bool
    private let memorySmokeEmptyPanelMode: Bool
    private let memorySmokeColoredPanel: Bool
    private lazy var historyStore = CaptureHistoryStore()
    private lazy var captureService = ScreenCaptureService()
    private lazy var ocrService = OCRService()
    private lazy var translationService = OpenAITranslationService(settings: settings)
    private var statusController: StatusItemController?
    private var captureCoordinator: CaptureCoordinator?
    private var isCaptureSessionActive = false
    private var preferencesWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var didInstallMainMenu = false

    init(
        memorySmokeMode: Bool = false,
        memorySmokeCopiesImage: Bool = false,
        memorySmokeToolbarCompletion: Bool = false,
        memorySmokeAnnotationPreview: Bool = false,
        memorySmokeHoldOverlay: Bool = false,
        memorySmokeEmptyPanelMode: Bool = false,
        memorySmokeColoredPanel: Bool = false
    ) {
        self.memorySmokeMode = memorySmokeMode
        self.memorySmokeCopiesImage = memorySmokeCopiesImage
        self.memorySmokeToolbarCompletion = memorySmokeToolbarCompletion
        self.memorySmokeAnnotationPreview = memorySmokeAnnotationPreview
        self.memorySmokeHoldOverlay = memorySmokeHoldOverlay
        self.memorySmokeEmptyPanelMode = memorySmokeEmptyPanelMode
        self.memorySmokeColoredPanel = memorySmokeColoredPanel
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(
            onCaptureArea: { [weak self] in self?.startCapture(mode: .area) },
            onCaptureFullScreen: { [weak self] in self?.startCapture(mode: .fullScreen) },
            onCaptureDelayed: { [weak self] in self?.startDelayedCapture() },
            onShowHistory: { [weak self] in self?.showHistory() },
            onShowPreferences: { [weak self] in self?.showPreferences() },
            onQuit: { NSApp.terminate(nil) }
        )

        configureHotKeys()

        settings.hotKeysDidChange = { [weak self] in
            self?.configureHotKeys()
        }

        if memorySmokeEmptyPanelMode {
            runMemorySmokeEmptyPanel()
        } else if memorySmokeMode {
            runMemorySmokeCapture()
        }
    }

    private func installMainMenuIfNeeded() {
        guard !didInstallMainMenu else { return }
        didInstallMainMenu = true

        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "偏好设置...", action: #selector(showPreferencesFromMenu), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 LiteShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "粘贴并匹配样式", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
        editMenu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showPreferencesFromMenu() {
        showPreferences()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureHotKeys() {
        HotKeyManager.shared.configure(
            captureAreaHotKey: settings.captureAreaHotKey,
            captureFullScreenHotKey: settings.captureFullScreenHotKey,
            captureArea: { [weak self] in self?.startCapture(mode: .area) },
            captureFullScreen: { [weak self] in self?.startCapture(mode: .fullScreen) }
        )
    }

    private func startDelayedCapture() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            startCapture(mode: .area)
        }
    }

    private func startCapture(mode: CaptureMode) {
        guard !isCaptureSessionActive else { return }
        isCaptureSessionActive = true

        Task { @MainActor in
            do {
                let snapshots = try await captureService.captureAllDisplays()
                if memorySmokeHoldOverlay {
                    dumpFrozenSnapshotsForMemorySmoke(snapshots)
                }
                let coordinator = CaptureCoordinator(
                    snapshots: snapshots,
                    mode: mode,
                    settings: settings,
                    historyStore: historyStore,
                    ocrService: ocrService,
                    translationService: translationService
                )
                captureCoordinator = coordinator
                coordinator.start { [weak self, weak coordinator] in
                    guard let self else { return }
                    if self.captureCoordinator === coordinator {
                        self.captureCoordinator = nil
                    }
                    self.isCaptureSessionActive = false
                }
            } catch {
                isCaptureSessionActive = false
                if memorySmokeMode {
                    print("memory-smoke error=start-capture-failed message=\(error.localizedDescription)")
                    fflush(stdout)
                }
                AlertPresenter.show(error.localizedDescription)
            }
        }
    }

    private func showPreferences() {
        installMainMenuIfNeeded()

        if let preferencesWindow {
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = PreferencesViewController(settings: settings)
        let window = NSWindow(contentViewController: controller)
        window.title = "偏好设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 580, height: 430))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        preferencesWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showHistory() {
        installMainMenuIfNeeded()

        if let historyWindow {
            historyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = HistoryViewController(store: historyStore)
        let window = NSWindow(contentViewController: controller)
        window.title = "历史记录"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 360, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func runMemorySmokeCapture() {
        Task { @MainActor in
            logMemorySmoke("baseline")
            try? await Task.sleep(for: .milliseconds(300))

            startCapture(mode: .fullScreen)
            try? await Task.sleep(for: .milliseconds(800))
            logMemorySmoke("overlay-visible")

            guard let coordinator = captureCoordinator else {
                print("memory-smoke error=no-capture-coordinator")
                NSApp.terminate(nil)
                return
            }

            if memorySmokeHoldOverlay {
                printVisibleWindowsForMemorySmoke()
                try? await Task.sleep(for: .seconds(8))
                coordinator.finishMemorySmoke()
                MemoryPressureRelief.releaseNow()
                try? await Task.sleep(for: .milliseconds(800))
                logMemorySmoke("after-hold-overlay-close")
                printVisibleWindowsForMemorySmoke()
                NSApp.terminate(nil)
                return
            }

            if memorySmokeToolbarCompletion {
                guard coordinator.triggerToolbarCompletionForMemorySmoke() else {
                    print("memory-smoke error=toolbar-complete-failed")
                    coordinator.finishMemorySmoke()
                    NSApp.terminate(nil)
                    return
                }
                PasteboardWriter.copy(text: "LiteShot memory smoke")
                MemoryPressureRelief.releaseNow()
                try? await Task.sleep(for: .milliseconds(800))
                logMemorySmoke("after-toolbar-complete")
                printVisibleWindowsForMemorySmoke()
                NSApp.terminate(nil)
                return
            }

            if memorySmokeAnnotationPreview {
                guard coordinator.showAnnotationPreviewForMemorySmoke() else {
                    print("memory-smoke error=annotation-preview-failed")
                    coordinator.finishMemorySmoke()
                    NSApp.terminate(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(800))
                logMemorySmoke("annotation-preview-visible")
                printVisibleWindowsForMemorySmoke()
                coordinator.finishMemorySmoke()
                MemoryPressureRelief.releaseNow()
                try? await Task.sleep(for: .milliseconds(800))
                logMemorySmoke("after-annotation-preview-close")
                printVisibleWindowsForMemorySmoke()
                NSApp.terminate(nil)
                return
            }

            var image = coordinator.renderSelectionForMemorySmoke()
            guard image != nil else {
                print("memory-smoke error=render-selection-failed")
                coordinator.finishMemorySmoke()
                NSApp.terminate(nil)
                return
            }
            logMemorySmoke("selection-image-held")

            if memorySmokeCopiesImage, let copiedImage = image {
                PasteboardWriter.copy(copiedImage)
                logMemorySmoke("image-copied")
                PasteboardWriter.copy(text: "LiteShot memory smoke")
                logMemorySmoke("pasteboard-cleared-to-text")
            }

            logMemorySmoke("panel-closed-image-held")

            image = nil
            MemoryPressureRelief.releaseNow()
            try? await Task.sleep(for: .milliseconds(800))
            logMemorySmoke("after-image-release")
            printVisibleWindowsForMemorySmoke()
            NSApp.terminate(nil)
        }
    }

    private func runMemorySmokeEmptyPanel() {
        Task { @MainActor in
            logMemorySmoke("baseline")
            guard let screen = NSScreen.main else {
                print("memory-smoke error=no-screen")
                NSApp.terminate(nil)
                return
            }
            let panel = CapturePanel(screenFrame: screen.frame)
            panel.backgroundColor = memorySmokeColoredPanel ? NSColor.black.withAlphaComponent(0.42) : .clear
            panel.contentView = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            panel.contentView?.wantsLayer = false
            panel.orderFrontRegardless()
            panel.makeKey()
            try? await Task.sleep(for: .milliseconds(800))
            logMemorySmoke("empty-panel-visible")
            panel.contentView = nil
            panel.orderOut(nil)
            panel.close()
            MemoryPressureRelief.releaseNow()
            try? await Task.sleep(for: .milliseconds(800))
            logMemorySmoke("after-panel-close")
            NSApp.terminate(nil)
        }
    }

    private func logMemorySmoke(_ phase: String) {
        if let footprint = MemoryPressureRelief.currentFootprintMegabytes() {
            print(String(format: "memory-smoke phase=%@ footprint_mb=%.1f", phase, footprint))
        } else {
            print("memory-smoke phase=\(phase) footprint_mb=unknown")
        }
        fflush(stdout)
    }

    private func dumpFrozenSnapshotsForMemorySmoke(_ snapshots: [ScreenSnapshot]) {
        for (index, snapshot) in snapshots.enumerated() {
            guard let data = ImageExporter.encodedData(for: snapshot.frozenImage, format: .png) else {
                continue
            }
            let url = URL(fileURLWithPath: "/tmp/liteshot-frozen-\(index).png")
            try? data.write(to: url, options: [.atomic])
            print("memory-smoke frozen_snapshot index=\(index) path=\(url.path) pixels=\(snapshot.frozenImage.width)x\(snapshot.frozenImage.height)")
        }
        fflush(stdout)
    }

    private func printVisibleWindowsForMemorySmoke() {
        let visibleWindows = NSApp.windows.filter { $0.isVisible }
        print("memory-smoke visible_windows=\(visibleWindows.count)")
        for window in visibleWindows {
            print("memory-smoke window id=\(window.windowNumber) class=\(type(of: window)) level=\(window.level.rawValue) frame=\(NSStringFromRect(window.frame)) title=\(window.title)")
        }
        fflush(stdout)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === preferencesWindow {
            preferencesWindow = nil
        }
        if window === historyWindow {
            historyWindow = nil
        }
    }
}
