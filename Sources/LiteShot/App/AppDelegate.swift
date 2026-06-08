import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let historyStore = CaptureHistoryStore()
    private let captureService = ScreenCaptureService()
    private let ocrService = OCRService()
    private let translationService = OpenAITranslationService(settings: .shared)
    private var statusController: StatusItemController?
    private var captureCoordinator: CaptureCoordinator?
    private var preferencesWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        statusController = StatusItemController(
            onCaptureArea: { [weak self] in self?.startCapture(mode: .area) },
            onCaptureFullScreen: { [weak self] in self?.startCapture(mode: .fullScreen) },
            onCaptureDelayed: { [weak self] in self?.startDelayedCapture() },
            onShowHistory: { [weak self] in self?.showHistory() },
            onShowPreferences: { [weak self] in self?.showPreferences() },
            onQuit: { NSApp.terminate(nil) }
        )

        configureHotKeys()

        settings.$captureAreaHotKey
            .combineLatest(settings.$captureFullScreenHotKey)
            .dropFirst()
            .sink { [weak self] _, _ in
                self?.configureHotKeys()
            }
            .store(in: &cancellables)
    }

    private func installMainMenu() {
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
        Task { @MainActor in
            do {
                let snapshot = try await captureService.captureMainDisplay()
                let coordinator = CaptureCoordinator(
                    snapshot: snapshot,
                    mode: mode,
                    settings: settings,
                    historyStore: historyStore,
                    ocrService: ocrService,
                    translationService: translationService
                )
                captureCoordinator = coordinator
                coordinator.start { [weak self] in
                    self?.captureCoordinator = nil
                }
            } catch {
                AlertPresenter.show(error.localizedDescription)
            }
        }
    }

    private func showPreferences() {
        if let preferencesWindow {
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PreferencesView(settings: settings)
        let controller = NSHostingController(rootView: view)
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
        if let historyWindow {
            historyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HistoryView(store: historyStore)
        let controller = NSHostingController(rootView: view)
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
