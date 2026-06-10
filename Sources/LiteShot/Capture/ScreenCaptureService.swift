import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

enum CaptureMode {
    case area
    case fullScreen
}

struct ScreenSnapshot {
    let screenFrame: CGRect
    let scale: CGFloat
    let displayID: CGDirectDisplayID
    let frozenImage: CGImage
}

enum ScreenCaptureError: LocalizedError {
    case missingDisplay
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .missingDisplay:
            "未找到可截图的显示器。"
        case .captureFailed:
            "无法截取屏幕。请在系统设置中为 LiteShot 或当前运行宿主授予“屏幕与系统音频录制”权限。"
        }
    }
}

@MainActor
final class ScreenCaptureService {
    func captureMainDisplay() async throws -> ScreenSnapshot {
        try await capture(screen: NSScreen.main)
    }

    func captureDisplayContainingMouse() async throws -> ScreenSnapshot {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return try await capture(screen: screen)
    }

    func captureAllDisplays() async throws -> [ScreenSnapshot] {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.captureFailed
        }

        let content = try await SCShareableContent.current
        let displaysByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        var snapshots: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let snapshot = try await capture(
                screen: screen,
                display: displaysByID[displayID(for: screen) ?? 0],
                shouldCheckPermission: false
            ) else {
                continue
            }
            snapshots.append(snapshot)
        }
        guard !snapshots.isEmpty else {
            throw ScreenCaptureError.missingDisplay
        }
        return snapshots
    }

    private func capture(screen: NSScreen?) async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.captureFailed
        }
        let content = try await SCShareableContent.current
        let displaysByID = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        guard let screen,
              let snapshot = try await capture(
            screen: screen,
            display: displaysByID[displayID(for: screen) ?? 0],
            shouldCheckPermission: false
        ) else {
            throw ScreenCaptureError.missingDisplay
        }
        return snapshot
    }

    private func capture(screen: NSScreen?, display: SCDisplay?, shouldCheckPermission: Bool) async throws -> ScreenSnapshot? {
        guard let screen, let displayID = displayID(for: screen), let display else {
            return nil
        }

        guard !shouldCheckPermission || CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.captureFailed
        }

        let frozenImage = try await captureImage(for: screen, display: display)

        let displayScale = max(
            CGFloat(frozenImage.width) / max(screen.frame.width, 1),
            CGFloat(frozenImage.height) / max(screen.frame.height, 1)
        )
        return ScreenSnapshot(
            screenFrame: screen.frame,
            scale: displayScale,
            displayID: displayID,
            frozenImage: frozenImage
        )
    }

    private func captureImage(for screen: NSScreen, display: SCDisplay) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(screen.frame.width * screen.backingScaleFactor))
        configuration.height = max(1, Int(screen.frame.height * screen.backingScaleFactor))
        configuration.showsCursor = false
        configuration.queueDepth = 1
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ScreenCaptureError.captureFailed)
                }
            }
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
