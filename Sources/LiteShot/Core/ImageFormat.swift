import AppKit

enum ImageFormat: String, CaseIterable, Identifiable, Codable {
    case png
    case jpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png:
            "PNG"
        case .jpeg:
            "JPEG"
        }
    }

    var fileExtension: String {
        rawValue
    }

    var bitmapType: NSBitmapImageRep.FileType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        }
    }
}
