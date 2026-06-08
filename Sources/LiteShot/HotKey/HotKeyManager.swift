import AppKit
import Carbon

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var captureAreaHandler: (() -> Void)?
    private var captureFullScreenHandler: (() -> Void)?
    private var captureAreaHotKey: HotKey = .defaultCaptureArea
    private var captureFullScreenHotKey: HotKey = .defaultCaptureFullScreen
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef?] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTriggerID: UInt32?
    private var lastTriggerTime: TimeInterval = 0

    private init() {}

    func configure(
        captureAreaHotKey: HotKey,
        captureFullScreenHotKey: HotKey,
        captureArea: @escaping () -> Void,
        captureFullScreen: @escaping () -> Void
    ) {
        self.captureAreaHotKey = captureAreaHotKey
        self.captureFullScreenHotKey = captureFullScreenHotKey
        captureAreaHandler = captureArea
        captureFullScreenHandler = captureFullScreen

        installHandlerIfNeeded()
        installEventMonitorIfNeeded()
        unregisterHotKeys()
        register(captureAreaHotKey, id: 1)
        register(captureFullScreenHotKey, id: 2)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            Task { @MainActor in
                manager.handleHotKey(id: hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    private func installEventMonitorIfNeeded() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
            return event
        }
    }

    private func register(_ hotKey: HotKey, id: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("LTSH"), id: id)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("LiteShot hotkey registration failed id=\(id) key=\(hotKey.displayString) status=\(status)")
        }
        hotKeys.append(hotKeyRef)
    }

    private func unregisterHotKeys() {
        for hotKey in hotKeys {
            if let hotKey {
                UnregisterEventHotKey(hotKey)
            }
        }
        hotKeys.removeAll()
    }

    private func handleHotKey(id: UInt32) {
        trigger(id: id)
    }

    private func handle(event: NSEvent) {
        if captureAreaHotKey.matches(event: event) {
            trigger(id: 1)
        } else if captureFullScreenHotKey.matches(event: event) {
            trigger(id: 2)
        }
    }

    private func trigger(id: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        if lastTriggerID == id, now - lastTriggerTime < 0.25 {
            return
        }
        lastTriggerID = id
        lastTriggerTime = now

        switch id {
        case 1:
            captureAreaHandler?()
        case 2:
            captureFullScreenHandler?()
        default:
            break
        }
    }
}

private func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
