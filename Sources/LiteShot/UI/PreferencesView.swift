import SwiftUI

struct PreferencesView: View {
    @ObservedObject var settings: AppSettings
    @State private var selectedTab: PreferenceTab = .general
    @State private var fetchedModels: [AIModelInfo] = []
    @State private var isFetchingModels = false
    @State private var modelFetchMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Form {
                switch selectedTab {
                case .general:
                    generalSection
                case .openAI:
                    openAISection
                }
            }
            .formStyle(.grouped)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 400)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(PreferenceTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title, systemImage: tab.symbolName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 150)
        .background(.quaternary.opacity(0.3))
    }

    private var generalSection: some View {
        Group {
            Section("保存行为") {
                Toggle("保存后同时复制到剪贴板", isOn: $settings.copyToClipboard)
                Toggle("播放声音", isOn: $settings.playSound)
                Toggle("显示光标和尺寸", isOn: $settings.showDimensions)
            }

            Section("保存") {
                Picker("图片格式", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                HStack {
                    TextField("保存位置", text: $settings.saveDirectory)
                    Button("选择...") {
                        chooseSaveDirectory()
                    }
                }
            }

            Section("快捷键") {
                HStack {
                    Text("截取区域")
                    Spacer()
                    HotKeyRecorder(hotKey: $settings.captureAreaHotKey)
                        .frame(width: 150, height: 28)
                }
                HStack {
                    Text("截取全屏")
                    Spacer()
                    HotKeyRecorder(hotKey: $settings.captureFullScreenHotKey)
                        .frame(width: 150, height: 28)
                }
            }
        }
    }

    private var openAISection: some View {
        Group {
            Section("OpenAI") {
                SecureField("API Key", text: $settings.openAIAPIKey)

                HStack {
                    TextField("API 地址", text: $settings.openAIBaseURL)
                        .onSubmit {
                            fillChatCompletionsEndpoint()
                        }
                    Button("补全") {
                        fillChatCompletionsEndpoint()
                    }
                    .help("自动补全为 /v1/chat/completions")
                }

                HStack {
                    TextField("模型", text: $settings.openAIModel)
                    Button {
                        Task { await fetchModels() }
                    } label: {
                        if isFetchingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("获取模型", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isFetchingModels || settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("从当前接口的 /v1/models 拉取模型列表")
                }

                if !modelChoices.isEmpty {
                    Picker("从列表选择", selection: $settings.openAIModel) {
                        ForEach(modelChoices, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                TextField("目标语言", text: $settings.translationTargetLanguage)

                Picker("思维链长度", selection: $settings.openAIThinkingLength) {
                    ForEach(thinkingChoices) { length in
                        Text(length.displayName).tag(length)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.openAIThinkingLength.detail(model: settings.openAIModel, endpoint: settings.openAIBaseURL))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let modelFetchMessage {
                    Text(modelFetchMessage)
                        .font(.footnote)
                        .foregroundStyle(modelFetchMessage.hasPrefix("已获取") ? Color.secondary : Color.red)
                }
            }

            Section {
                Text("API Key 保存在本机 Keychain；API 地址默认使用兼容 OpenAI 的 /v1/chat/completions；模型列表会从同域 /v1/models 获取。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            fillChatCompletionsEndpoint()
            normalizeThinkingSelection()
        }
        .onDisappear {
            fillChatCompletionsEndpoint()
            normalizeThinkingSelection()
        }
        .onChange(of: settings.openAIModel) { _, _ in
            normalizeThinkingSelection()
        }
        .onChange(of: settings.openAIBaseURL) { _, _ in
            normalizeThinkingSelection()
        }
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

    @MainActor
    private func fetchModels() async {
        fillChatCompletionsEndpoint()
        isFetchingModels = true
        modelFetchMessage = nil
        defer { isFetchingModels = false }

        do {
            let service = OpenAITranslationService(settings: settings)
            let models = try await service.fetchModels()
            fetchedModels = models
            if settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = models.first?.id {
                settings.openAIModel = first
            }
            normalizeThinkingSelection()
            modelFetchMessage = "已获取 \(models.count) 个模型。"
        } catch {
            modelFetchMessage = error.localizedDescription
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url.path
        }
    }
}

private enum PreferenceTab: String, CaseIterable, Identifiable {
    case general
    case openAI

    var id: String { rawValue }

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
