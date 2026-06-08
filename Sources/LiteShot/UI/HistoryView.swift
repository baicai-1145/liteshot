import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: CaptureHistoryStore

    var body: some View {
        VStack(spacing: 0) {
            List(store.items) { item in
                HistoryRow(item: item)
                    .contextMenu {
                        Button("复制图片") {
                            copyImage(item)
                        }
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
                        }
                    }
            }
            HStack {
                Button("清空历史记录") {
                    store.clear()
                }
                .disabled(store.items.isEmpty)
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 320, minHeight: 420)
    }

    private func copyImage(_ item: CaptureHistoryItem) {
        guard let image = NSImage(contentsOf: item.imageURL) else { return }
        PasteboardWriter.copy(image: image)
    }
}

private struct HistoryRow: View {
    let item: CaptureHistoryItem

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(url: item.imageURL)
                .frame(width: 76, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.system(size: 12, weight: .semibold))
                Text("\(item.pixelWidth) × \(item.pixelHeight)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let translation = item.translation, !translation.isEmpty {
                    Text(translation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ThumbnailView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.image = NSImage(contentsOf: url)
    }
}
