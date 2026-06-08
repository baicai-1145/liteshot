import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem

    init(
        onCaptureArea: @escaping () -> Void,
        onCaptureFullScreen: @escaping () -> Void,
        onCaptureDelayed: @escaping () -> Void,
        onShowHistory: @escaping () -> Void,
        onShowPreferences: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "LiteShot")
            button.toolTip = "LiteShot"
        }

        let menu = NSMenu()
        menu.addItem(MenuItemFactory.item("截取区域", key: "1", action: onCaptureArea))
        menu.addItem(MenuItemFactory.item("截取全屏", key: "2", action: onCaptureFullScreen))
        menu.addItem(MenuItemFactory.item("延时截图", key: "3", action: onCaptureDelayed))
        menu.addItem(.separator())
        menu.addItem(MenuItemFactory.item("历史记录", key: "h", action: onShowHistory))
        menu.addItem(MenuItemFactory.item("偏好设置...", key: ",", action: onShowPreferences))
        menu.addItem(.separator())
        menu.addItem(MenuItemFactory.item("退出", key: "q", action: onQuit))
        statusItem.menu = menu
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runHandler() {
        handler()
    }
}

private enum MenuItemFactory {
    static func item(_ title: String, key: String, action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, keyEquivalent: key, handler: action)
    }
}
