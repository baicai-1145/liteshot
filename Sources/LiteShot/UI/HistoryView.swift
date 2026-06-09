import AppKit

@MainActor
final class HistoryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: CaptureHistoryStore
    private let tableView = HistoryTableView()
    private let clearButton = NSButton(title: "清空历史记录", target: nil, action: nil)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    init(store: CaptureHistoryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        store.onChange = { [weak self] in
            self?.reloadHistory()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 560))
        buildView()
        reloadHistory()
    }

    private func buildView() {
        tableView.headerView = nil
        tableView.rowHeight = 68
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menuProvider = { [weak self] row in
            self?.menu(for: row)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        clearButton.target = self
        clearButton.action = #selector(clearHistory)
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(clearButton)

        view.addSubview(scrollView)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),
            clearButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            clearButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }

    private func reloadHistory() {
        tableView.reloadData()
        clearButton.isEnabled = !store.items.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard store.items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryCellView ?? HistoryCellView()
        cell.identifier = identifier
        let item = store.items[row]
        cell.configure(
            item: item,
            dateText: dateFormatter.string(from: item.createdAt)
        )
        return cell
    }

    private func menu(for row: Int) -> NSMenu? {
        guard store.items.indices.contains(row) else { return nil }
        let item = store.items[row]
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "复制图片", keyEquivalent: "") {
            guard let image = NSImage(contentsOf: item.imageURL) else { return }
            PasteboardWriter.copy(image: image)
        })
        menu.addItem(ClosureMenuItem(title: "在 Finder 中显示", keyEquivalent: "") {
            NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
        })
        return menu
    }

    @objc private func clearHistory() {
        store.clear()
    }
}

@MainActor
private final class HistoryCellView: NSTableCellView {
    private let thumbnailView = NSImageView()
    private let dateLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let translationLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildView() {
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 4
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        dateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        translationLabel.font = .systemFont(ofSize: 11)
        translationLabel.textColor = .secondaryLabelColor
        translationLabel.maximumNumberOfLines = 2

        let labels = NSStackView(views: [dateLabel, sizeLabel, translationLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumbnailView)
        addSubview(labels)

        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 76),
            thumbnailView.heightAnchor.constraint(equalToConstant: 52),
            labels.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(item: CaptureHistoryItem, dateText: String) {
        thumbnailView.image = NSImage(contentsOf: item.imageURL)
        dateLabel.stringValue = dateText
        sizeLabel.stringValue = "\(item.pixelWidth) × \(item.pixelHeight)"
        translationLabel.stringValue = item.translation ?? ""
        translationLabel.isHidden = (item.translation ?? "").isEmpty
    }
}

@MainActor
private final class HistoryTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return menuProvider?(row)
    }
}

@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runHandler() {
        handler()
    }
}
