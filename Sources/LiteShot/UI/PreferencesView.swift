import AppKit

@MainActor
final class PreferencesViewController: NSViewController {
    private let settings: AppSettings
    private var selectedTab: PreferenceTab = .general
    private var fetchedModels: [AIModelInfo] = []
    private var isFetchingModels = false

    private let sidebarStack = NSStackView()
    private let contentContainer = NSView()
    private let contentStack = NSStackView()
    private var tabButtons: [PreferenceTab: CallbackButton] = [:]

    private var endpointField: CallbackTextField?
    private var modelField: CallbackTextField?
    private var modelPopup: CallbackPopUpButton?
    private var thinkingPopup: CallbackPopUpButton?
    private var thinkingDetailLabel: NSTextField?
    private var fetchModelsButton: CallbackButton?
    private var modelFetchMessageLabel: NSTextField?

    init(settings: AppSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 430))
        buildRootView()
        selectTab(.general)
    }

    private func buildRootView() {
        let rootStack = NSStackView()
        rootStack.orientation = .horizontal
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 6
        sidebarStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSView()
        sidebar.addSubview(sidebarStack)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor

        for tab in PreferenceTab.allCases {
            let button = CallbackButton(title: tab.title) { [weak self] _ in
                self?.selectTab(tab)
            }
            button.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.isBordered = false
            button.setButtonType(.toggle)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 126).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            tabButtons[tab] = button
            sidebarStack.addArrangedSubview(button)
        }
        sidebarStack.addArrangedSubview(NSView())

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16
        contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentStack)

        rootStack.addArrangedSubview(sidebar)
        rootStack.addArrangedSubview(contentContainer)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 150),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor)
        ])
    }

    private func selectTab(_ tab: PreferenceTab) {
        selectedTab = tab
        for (item, button) in tabButtons {
            button.state = item == tab ? .on : .off
        }
        rebuildContent()
    }

    private func rebuildContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch selectedTab {
        case .general:
            buildGeneralContent()
        case .openAI:
            fillChatCompletionsEndpoint()
            normalizeThinkingSelection()
            buildOpenAIContent()
        }
    }

    private func buildGeneralContent() {
        contentStack.addArrangedSubview(makeSection("保存行为", rows: [
            checkbox("保存后同时复制到剪贴板", value: settings.copyToClipboard) { [weak self] value in
                self?.settings.copyToClipboard = value
            },
            checkbox("播放声音", value: settings.playSound) { [weak self] value in
                self?.settings.playSound = value
            },
            checkbox("显示光标和尺寸", value: settings.showDimensions) { [weak self] value in
                self?.settings.showDimensions = value
            }
        ]))

        let formatPopup = CallbackPopUpButton { [weak self] popup in
            guard
                let rawValue = popup.selectedItem?.representedObject as? String,
                let format = ImageFormat(rawValue: rawValue)
            else { return }
            self?.settings.imageFormat = format
        }
        for format in ImageFormat.allCases {
            formatPopup.addItem(withTitle: format.displayName)
            formatPopup.lastItem?.representedObject = format.rawValue
        }
        formatPopup.selectItem(withTitle: settings.imageFormat.displayName)

        let savePathField = CallbackTextField(value: settings.saveDirectory, placeholder: "保存位置") { [weak self] value in
            self?.settings.saveDirectory = value
        }
        savePathField.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let chooseButton = CallbackButton(title: "选择...") { [weak self] _ in
            self?.chooseSaveDirectory(savePathField: savePathField)
        }

        let savePathControls = NSStackView(views: [savePathField, chooseButton])
        savePathControls.orientation = .horizontal
        savePathControls.spacing = 8

        contentStack.addArrangedSubview(makeSection("保存", rows: [
            row(label: "图片格式", control: formatPopup),
            row(label: "保存位置", control: savePathControls)
        ]))

        let areaRecorder = HotKeyRecorderView(hotKey: settings.captureAreaHotKey) { [weak self] hotKey in
            self?.settings.captureAreaHotKey = hotKey
        }
        areaRecorder.translatesAutoresizingMaskIntoConstraints = false
        areaRecorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        areaRecorder.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let fullRecorder = HotKeyRecorderView(hotKey: settings.captureFullScreenHotKey) { [weak self] hotKey in
            self?.settings.captureFullScreenHotKey = hotKey
        }
        fullRecorder.translatesAutoresizingMaskIntoConstraints = false
        fullRecorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        fullRecorder.heightAnchor.constraint(equalToConstant: 28).isActive = true

        contentStack.addArrangedSubview(makeSection("快捷键", rows: [
            row(label: "截取区域", control: areaRecorder),
            row(label: "截取全屏", control: fullRecorder)
        ]))
    }

    private func buildOpenAIContent() {
        settings.loadOpenAIAPIKeyIfNeeded()
        let apiKeyField = CallbackSecureTextField(value: settings.openAIAPIKey, placeholder: "API Key") { [weak self] value in
            self?.settings.openAIAPIKey = value
            self?.refreshFetchModelsButton()
        }
        apiKeyField.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let endpointField = CallbackTextField(value: settings.openAIBaseURL, placeholder: "API 地址") { [weak self] value in
            self?.settings.openAIBaseURL = value
            self?.normalizeThinkingSelection()
            self?.refreshThinkingControls()
        }
        endpointField.widthAnchor.constraint(equalToConstant: 286).isActive = true
        self.endpointField = endpointField

        let fillButton = CallbackButton(title: "补全") { [weak self] _ in
            self?.fillChatCompletionsEndpoint()
            endpointField.stringValue = self?.settings.openAIBaseURL ?? endpointField.stringValue
            self?.refreshThinkingControls()
        }

        let endpointControls = NSStackView(views: [endpointField, fillButton])
        endpointControls.orientation = .horizontal
        endpointControls.spacing = 8

        let modelField = CallbackTextField(value: settings.openAIModel, placeholder: "模型") { [weak self] value in
            self?.settings.openAIModel = value
            self?.normalizeThinkingSelection()
            self?.refreshModelPopup()
            self?.refreshThinkingControls()
        }
        modelField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        self.modelField = modelField

        let fetchButton = CallbackButton(title: "获取模型") { [weak self] _ in
            self?.fetchModels()
        }
        fetchModelsButton = fetchButton
        refreshFetchModelsButton()

        let modelControls = NSStackView(views: [modelField, fetchButton])
        modelControls.orientation = .horizontal
        modelControls.spacing = 8

        let modelPopup = CallbackPopUpButton { [weak self] popup in
            guard let model = popup.selectedItem?.representedObject as? String else { return }
            self?.settings.openAIModel = model
            self?.modelField?.stringValue = model
            self?.normalizeThinkingSelection()
            self?.refreshThinkingControls()
        }
        modelPopup.widthAnchor.constraint(equalToConstant: 330).isActive = true
        self.modelPopup = modelPopup

        let targetField = CallbackTextField(value: settings.translationTargetLanguage, placeholder: "目标语言") { [weak self] value in
            self?.settings.translationTargetLanguage = value
        }
        targetField.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let thinkingPopup = CallbackPopUpButton { [weak self] popup in
            guard
                let rawValue = popup.selectedItem?.representedObject as? String,
                let thinkingLength = AIThinkingLength(rawValue: rawValue)
            else { return }
            self?.settings.openAIThinkingLength = thinkingLength
            self?.refreshThinkingDetail()
        }
        thinkingPopup.widthAnchor.constraint(equalToConstant: 330).isActive = true
        self.thinkingPopup = thinkingPopup

        let detailLabel = secondaryLabel("")
        detailLabel.widthAnchor.constraint(equalToConstant: 360).isActive = true
        thinkingDetailLabel = detailLabel

        let messageLabel = secondaryLabel("")
        messageLabel.widthAnchor.constraint(equalToConstant: 360).isActive = true
        modelFetchMessageLabel = messageLabel

        contentStack.addArrangedSubview(makeSection("OpenAI", rows: [
            row(label: "API Key", control: apiKeyField),
            row(label: "API 地址", control: endpointControls),
            row(label: "模型", control: modelControls),
            row(label: "从列表选择", control: modelPopup),
            row(label: "目标语言", control: targetField),
            row(label: "思维链长度", control: thinkingPopup),
            detailLabel,
            messageLabel
        ]))

        contentStack.addArrangedSubview(makeSection(nil, rows: [
            secondaryLabel("API Key 保存在本机 Keychain；API 地址默认使用兼容 OpenAI 的 /v1/chat/completions；模型列表会从同域 /v1/models 获取。")
        ]))

        refreshModelPopup()
        refreshThinkingControls()
    }

    private func makeSection(_ title: String?, rows: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 382).isActive = true

        if let title {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            stack.addArrangedSubview(titleLabel)
        }

        for row in rows {
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func row(label title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func checkbox(_ title: String, value: Bool, onChange: @escaping (Bool) -> Void) -> CallbackButton {
        let button = CallbackButton(title: title) { sender in
            onChange(sender.state == .on)
        }
        button.setButtonType(.switch)
        button.state = value ? .on : .off
        return button
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private var thinkingChoices: [AIThinkingLength] {
        if let options = fetchedModels.first(where: { $0.id == settings.openAIModel })?.reasoningOptions, !options.isEmpty {
            return options
        }
        return AIThinkingLength.availableOptions(model: settings.openAIModel, endpoint: settings.openAIBaseURL)
    }

    private var modelChoices: [String] {
        ([settings.openAIModel] + fetchedModels.map(\.id))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
    }

    private func fillChatCompletionsEndpoint() {
        settings.openAIBaseURL = OpenAIEndpoint.chatCompletionsURLString(from: settings.openAIBaseURL)
    }

    private func normalizeThinkingSelection() {
        let options = thinkingChoices
        settings.openAIThinkingLength = options.contains(settings.openAIThinkingLength)
            ? settings.openAIThinkingLength
            : (options.first ?? .off)
    }

    private func refreshFetchModelsButton() {
        fetchModelsButton?.isEnabled = !isFetchingModels && !settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        fetchModelsButton?.title = isFetchingModels ? "获取中..." : "获取模型"
    }

    private func refreshModelPopup() {
        guard let modelPopup else { return }
        modelPopup.removeAllItems()
        for model in modelChoices {
            modelPopup.addItem(withTitle: model)
            modelPopup.lastItem?.representedObject = model
        }
        modelPopup.selectItem(withTitle: settings.openAIModel)
    }

    private func refreshThinkingControls() {
        guard let thinkingPopup else { return }
        thinkingPopup.removeAllItems()
        for option in thinkingChoices {
            thinkingPopup.addItem(withTitle: option.displayName)
            thinkingPopup.lastItem?.representedObject = option.rawValue
        }
        thinkingPopup.selectItem(withTitle: settings.openAIThinkingLength.displayName)
        refreshThinkingDetail()
    }

    private func refreshThinkingDetail() {
        thinkingDetailLabel?.stringValue = settings.openAIThinkingLength.detail(
            model: settings.openAIModel,
            endpoint: settings.openAIBaseURL
        )
    }

    private func setModelFetchMessage(_ message: String?, isError: Bool = false) {
        modelFetchMessageLabel?.stringValue = message ?? ""
        modelFetchMessageLabel?.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func fetchModels() {
        fillChatCompletionsEndpoint()
        endpointField?.stringValue = settings.openAIBaseURL
        isFetchingModels = true
        setModelFetchMessage(nil)
        refreshFetchModelsButton()

        Task { @MainActor in
            defer {
                isFetchingModels = false
                refreshFetchModelsButton()
            }

            do {
                let service = OpenAITranslationService(settings: settings)
                let models = try await service.fetchModels()
                fetchedModels = models
                if settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = models.first?.id {
                    settings.openAIModel = first
                    modelField?.stringValue = first
                }
                normalizeThinkingSelection()
                refreshModelPopup()
                refreshThinkingControls()
                setModelFetchMessage("已获取 \(models.count) 个模型。")
            } catch {
                setModelFetchMessage(error.localizedDescription, isError: true)
            }
        }
    }

    private func chooseSaveDirectory(savePathField: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url.path
            savePathField.stringValue = url.path
        }
    }
}

private enum PreferenceTab: String, CaseIterable {
    case general
    case openAI

    var title: String {
        switch self {
        case .general:
            "通用"
        case .openAI:
            "AI 翻译"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            "gearshape"
        case .openAI:
            "character.book.closed"
        }
    }
}

@MainActor
private final class CallbackButton: NSButton {
    private let handler: (NSButton) -> Void

    init(title: String, handler: @escaping (NSButton) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(run)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler(self)
    }
}

@MainActor
private final class CallbackPopUpButton: NSPopUpButton {
    private let handler: (NSPopUpButton) -> Void

    init(handler: @escaping (NSPopUpButton) -> Void) {
        self.handler = handler
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(run)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler(self)
    }
}

@MainActor
private final class CallbackTextField: NSTextField, NSTextFieldDelegate {
    private let onChange: (String) -> Void

    init(value: String, placeholder: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
        delegate = self
        isEditable = true
        isSelectable = true
        lineBreakMode = .byTruncatingMiddle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange(stringValue)
    }
}

@MainActor
private final class CallbackSecureTextField: NSSecureTextField, NSTextFieldDelegate {
    private let onChange: (String) -> Void

    init(value: String, placeholder: String, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
        delegate = self
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange(stringValue)
    }
}
