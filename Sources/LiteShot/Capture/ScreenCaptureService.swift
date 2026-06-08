import AppKit
import CoreGraphics

enum CaptureMode {
    case area
    case fullScreen
}

struct ScreenSnapshot {
    let image: NSImage
    let screenFrame: CGRect
    let scale: CGFloat
}

enum ScreenCaptureError: LocalizedError {
    case missingMainDisplay
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .missingMainDisplay:
            "未找到主显示器。"
        case .captureFailed:
            "无法截取屏幕。请在系统设置中为 LiteShot 或当前运行宿主授予“屏幕与系统音频录制”权限。"
        }
    }
}

@MainActor
final class ScreenCaptureService {
    func captureMainDisplay() async throws -> ScreenSnapshot {
        guard let screen = NSScreen.main else {
            throw ScreenCaptureError.missingMainDisplay
        }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw ScreenCaptureError.captureFailed
        }

        let displayID = CGMainDisplayID()
        guard let cgImage = CGDisplayCreateImage(displayID) else {
            throw ScreenCaptureError.captureFailed
        }

        let image = NSImage(cgImage: cgImage, size: screen.frame.size)
        return ScreenSnapshot(image: image, screenFrame: screen.frame, scale: screen.backingScaleFactor)
    }
}
