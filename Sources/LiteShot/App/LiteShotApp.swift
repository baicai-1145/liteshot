import AppKit

@main
enum LiteShotApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate(
            memorySmokeMode: CommandLine.arguments.contains("--memory-smoke-capture"),
            memorySmokeCopiesImage: CommandLine.arguments.contains("--memory-smoke-copy"),
            memorySmokeToolbarCompletion: CommandLine.arguments.contains("--memory-smoke-toolbar-complete"),
            memorySmokeAnnotationPreview: CommandLine.arguments.contains("--memory-smoke-annotation-preview"),
            memorySmokeHoldOverlay: CommandLine.arguments.contains("--memory-smoke-hold-overlay"),
            memorySmokeEmptyPanelMode: CommandLine.arguments.contains("--memory-smoke-empty-panel"),
            memorySmokeColoredPanel: CommandLine.arguments.contains("--memory-smoke-colored-panel")
        )
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
