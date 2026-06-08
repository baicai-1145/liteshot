import AppKit

@MainActor
enum AlertPresenter {
    static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "LiteShot"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    static func showText(title: String, text: String, emptyMessage: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            show(emptyMessage)
            return
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        textView.string = trimmed
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "结果已复制到剪贴板。"
        alert.accessoryView = scrollView
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "再次复制")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            PasteboardWriter.copy(text: trimmed)
        }
    }
}
