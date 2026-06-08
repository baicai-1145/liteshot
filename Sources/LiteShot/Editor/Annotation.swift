import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow
    case rectangle
    case text
    case pen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrow:
            "箭头"
        case .rectangle:
            "矩形"
        case .text:
            "文本"
        case .pen:
            "画笔"
        }
    }

    var symbolName: String {
        switch self {
        case .arrow:
            "arrow.up.right"
        case .rectangle:
            "rectangle"
        case .text:
            "textformat"
        case .pen:
            "pencil"
        }
    }
}

enum AnnotationShape {
    case arrow(start: CGPoint, end: CGPoint, color: NSColor)
    case rectangle(CGRect, NSColor)
    case text(String, CGPoint, NSColor)
    case pen([CGPoint], NSColor)
}
