import AppKit
import Foundation

@MainActor
final class CaptureHistoryStore {
    private(set) var items: [CaptureHistoryItem] = []
    var onChange: (() -> Void)?
    private let maximumItems = 50

    init() {
        load()
    }

    @discardableResult
    func add(imageURL: URL, pixelSize: CGSize, ocrText: String? = nil, translation: String? = nil) -> UUID {
        let item = CaptureHistoryItem(
            id: UUID(),
            createdAt: Date(),
            imagePath: imageURL.path,
            pixelWidth: Int(pixelSize.width.rounded()),
            pixelHeight: Int(pixelSize.height.rounded()),
            ocrText: ocrText,
            translation: translation
        )
        items.insert(item, at: 0)
        items = Array(items.prefix(maximumItems))
        save()
        onChange?()
        return item.id
    }

    func update(id: UUID, ocrText: String? = nil, translation: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let ocrText {
            items[index].ocrText = ocrText
        }
        if let translation {
            items[index].translation = translation
        }
        save()
        onChange?()
    }

    func clear() {
        items.removeAll()
        save()
        onChange?()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: FileLocations.historyFile)
            items = try JSONDecoder().decode([CaptureHistoryItem].self, from: data)
        } catch {
            items = []
        }
    }

    private func save() {
        do {
            try FileLocations.ensureDirectories()
            let data = try JSONEncoder.pretty.encode(items)
            try data.write(to: FileLocations.historyFile, options: [.atomic])
        } catch {
            NSLog("LiteShot history save failed: \(error.localizedDescription)")
        }
    }
}

struct CaptureHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let imagePath: String
    let pixelWidth: Int
    let pixelHeight: Int
    var ocrText: String?
    var translation: String?

    var imageURL: URL {
        URL(fileURLWithPath: imagePath)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
