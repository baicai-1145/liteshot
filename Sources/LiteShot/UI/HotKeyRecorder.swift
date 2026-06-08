import AppKit
import SwiftUI

struct HotKeyRecorder: NSViewRepresentable {
    @Binding var hotKey: HotKey

    func makeNSView(context: Context) -> HotKeyRecorderView {
        HotKeyRecorderView(hotKey: hotKey) { newValue in
            hotKey = newValue
        }
    }

    func updateNSView(_ nsView: HotKeyRecorderView, context: Context) {
        nsView.hotKey = hotKey
    }
}

final class HotKeyRecorderView: NSView {
    var hotKey: HotKey {
        didSet {
            label.stringValue = hotKey.displayString
            updateAppearanceColors()
        }
    }

    private let label = NSTextField(labelWithString: "")
    private let onChange: (HotKey) -> Void
    private var isRecording = false {
        didSet {
            label.stringValue = isRecording ? "按下快捷键" : hotKey.displayString
            updateAppearanceColors()
            needsDisplay = true
        }
    }

    init(hotKey: HotKey, onChange: @escaping (HotKey) -> Void) {
        self.hotKey = hotKey
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 28))
        wantsLayer = true
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.stringValue = hotKey.displayString
        addSubview(label)
        updateAppearanceColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 5)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        updateAppearanceColors()
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        backgroundColor.setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        guard let newHotKey = HotKey(event: event) else { return }
        hotKey = newHotKey
        isRecording = false
        onChange(newHotKey)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private func updateAppearanceColors() {
        label.appearance = window?.effectiveAppearance ?? effectiveAppearance
        label.textColor = isDarkAppearance ? .white : .black
    }

    private var backgroundColor: NSColor {
        isDarkAppearance ? NSColor(calibratedWhite: 0.24, alpha: 1) : .white
    }

    private var isDarkAppearance: Bool {
        if window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
