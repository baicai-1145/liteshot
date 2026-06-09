import Foundation

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    var hotKeysDidChange: (() -> Void)?
    private var didLoadOpenAIAPIKey = false

    var copyToClipboard: Bool {
        didSet { defaults.set(copyToClipboard, forKey: Keys.copyToClipboard) }
    }

    var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }

    var showDimensions: Bool {
        didSet { defaults.set(showDimensions, forKey: Keys.showDimensions) }
    }

    var imageFormat: ImageFormat {
        didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) }
    }

    var saveDirectory: String {
        didSet { defaults.set(saveDirectory, forKey: Keys.saveDirectory) }
    }

    var openAIAPIKey: String {
        didSet {
            if openAIAPIKey.isEmpty {
                KeychainStore.remove(service: Keys.keychainService, account: Keys.openAIAPIKey)
            } else {
                KeychainStore.set(openAIAPIKey, service: Keys.keychainService, account: Keys.openAIAPIKey)
            }
        }
    }

    var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Keys.openAIModel) }
    }

    var translationTargetLanguage: String {
        didSet { defaults.set(translationTargetLanguage, forKey: Keys.translationTargetLanguage) }
    }

    var openAIBaseURL: String {
        didSet { defaults.set(openAIBaseURL, forKey: Keys.openAIBaseURL) }
    }

    var openAIThinkingLength: AIThinkingLength {
        didSet { defaults.set(openAIThinkingLength.rawValue, forKey: Keys.openAIThinkingLength) }
    }

    var captureAreaHotKey: HotKey {
        didSet {
            store(captureAreaHotKey, forKey: Keys.captureAreaHotKey)
            hotKeysDidChange?()
        }
    }

    var captureFullScreenHotKey: HotKey {
        didSet {
            store(captureFullScreenHotKey, forKey: Keys.captureFullScreenHotKey)
            hotKeysDidChange?()
        }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        copyToClipboard = defaults.object(forKey: Keys.copyToClipboard) as? Bool ?? true
        playSound = defaults.object(forKey: Keys.playSound) as? Bool ?? true
        showDimensions = defaults.object(forKey: Keys.showDimensions) as? Bool ?? true
        imageFormat = ImageFormat(rawValue: defaults.string(forKey: Keys.imageFormat) ?? "") ?? .png
        saveDirectory = defaults.string(forKey: Keys.saveDirectory) ?? FileLocations.defaultSaveDirectory.path
        openAIAPIKey = defaults.string(forKey: Keys.openAIAPIKey) ?? ""
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "gpt-5.5"
        translationTargetLanguage = defaults.string(forKey: Keys.translationTargetLanguage) ?? "简体中文"
        openAIBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? "https://api.openai.com/v1/chat/completions"
        openAIThinkingLength = AIThinkingLength(rawValue: defaults.string(forKey: Keys.openAIThinkingLength) ?? "") ?? .off
        captureAreaHotKey = Self.loadHotKey(from: defaults, key: Keys.captureAreaHotKey) ?? .defaultCaptureArea
        captureFullScreenHotKey = Self.loadHotKey(from: defaults, key: Keys.captureFullScreenHotKey) ?? .defaultCaptureFullScreen
    }

    func loadOpenAIAPIKeyIfNeeded() {
        guard !didLoadOpenAIAPIKey else { return }
        didLoadOpenAIAPIKey = true

        if !openAIAPIKey.isEmpty {
            KeychainStore.set(openAIAPIKey, service: Keys.keychainService, account: Keys.openAIAPIKey)
            defaults.removeObject(forKey: Keys.openAIAPIKey)
            return
        }

        openAIAPIKey = KeychainStore.string(service: Keys.keychainService, account: Keys.openAIAPIKey) ?? ""
    }

    private func store(_ hotKey: HotKey, forKey key: String) {
        guard let data = try? JSONEncoder().encode(hotKey) else { return }
        defaults.set(data, forKey: key)
    }

    private static func loadHotKey(from defaults: UserDefaults, key: String) -> HotKey? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKey.self, from: data)
    }
}

extension AppSettings {
    enum Keys {
        static let keychainService = "local.baicai1145.liteshot"
        static let copyToClipboard = "copyToClipboard"
        static let playSound = "playSound"
        static let showDimensions = "showDimensions"
        static let imageFormat = "imageFormat"
        static let saveDirectory = "saveDirectory"
        static let openAIAPIKey = "openAIAPIKey"
        static let openAIModel = "openAIModel"
        static let translationTargetLanguage = "translationTargetLanguage"
        static let openAIBaseURL = "openAIBaseURL"
        static let openAIThinkingLength = "openAIThinkingLength"
        static let captureAreaHotKey = "captureAreaHotKey"
        static let captureFullScreenHotKey = "captureFullScreenHotKey"
    }
}

enum AIThinkingLength: String, CaseIterable, Identifiable, Sendable, Codable {
    case off
    case providerShort = "short"
    case providerMedium = "medium"
    case providerLong = "long"
    case openAIMinimal = "openai_minimal"
    case openAILow = "openai_low"
    case openAIMedium = "openai_medium"
    case openAIHigh = "openai_high"
    case openAIXHigh = "openai_xhigh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            "关闭 / none"
        case .providerShort:
            "短"
        case .providerMedium:
            "中"
        case .providerLong:
            "长"
        case .openAIMinimal:
            "minimal"
        case .openAILow:
            "low"
        case .openAIMedium:
            "medium"
        case .openAIHigh:
            "high"
        case .openAIXHigh:
            "xhigh"
        }
    }

    func detail(model: String, endpoint: String) -> String {
        switch self {
        case .off:
            if Self.isOpenAIReasoningModel(model) {
                return "OpenAI reasoning.effort = none，最低延迟。"
            }
            return "不发送推理参数，适合非 reasoning 模型。"
        case .providerShort:
            return "Qwen/ModelScope thinking_budget 64，保留少量推理。"
        case .providerMedium:
            return "Qwen/ModelScope thinking_budget 256，速度和推理量折中。"
        case .providerLong:
            return "Qwen/ModelScope thinking_budget 1024，速度明显变慢。"
        case .openAIMinimal:
            return "OpenAI reasoning.effort = minimal。"
        case .openAILow:
            return "OpenAI reasoning.effort = low。"
        case .openAIMedium:
            return "OpenAI reasoning.effort = medium。"
        case .openAIHigh:
            return "OpenAI reasoning.effort = high。"
        case .openAIXHigh:
            return "OpenAI reasoning.effort = xhigh。"
        }
    }

    var thinkingBudget: Int? {
        switch self {
        case .off:
            nil
        case .providerShort:
            64
        case .providerMedium:
            256
        case .providerLong:
            1024
        case .openAIMinimal, .openAILow, .openAIMedium, .openAIHigh, .openAIXHigh:
            nil
        }
    }

    var isThinkingEnabled: Bool {
        self != .off
    }

    var openAIReasoningEffort: String? {
        switch self {
        case .off:
            "none"
        case .openAIMinimal:
            "minimal"
        case .openAILow:
            "low"
        case .openAIMedium:
            "medium"
        case .openAIHigh:
            "high"
        case .openAIXHigh:
            "xhigh"
        case .providerShort, .providerMedium, .providerLong:
            nil
        }
    }

    static func availableOptions(model: String, endpoint: String) -> [AIThinkingLength] {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEndpoint = endpoint.lowercased()

        if isProviderThinkingModel(model: normalizedModel, endpoint: normalizedEndpoint) {
            return [.off, .providerShort, .providerMedium, .providerLong]
        }

        if normalizedModel.hasPrefix("gpt-5.5") || normalizedModel.hasPrefix("gpt-5.4") {
            return [.off, .openAILow, .openAIMedium, .openAIHigh, .openAIXHigh]
        }

        if normalizedModel.hasPrefix("gpt-5.1") {
            return [.off, .openAILow, .openAIMedium, .openAIHigh]
        }

        if normalizedModel == "gpt-5" || normalizedModel.hasPrefix("gpt-5-") {
            return [.openAIMinimal, .openAILow, .openAIMedium, .openAIHigh]
        }

        if normalizedModel.hasPrefix("o1") || normalizedModel.hasPrefix("o3") || normalizedModel.hasPrefix("o4") {
            return [.openAILow, .openAIMedium, .openAIHigh]
        }

        return [.off]
    }

    static func normalized(_ value: AIThinkingLength, model: String, endpoint: String) -> AIThinkingLength {
        let options = availableOptions(model: model, endpoint: endpoint)
        return options.contains(value) ? value : (options.first ?? .off)
    }

    static func options(openAIEfforts: [String], thinkingBudgets: [Int]) -> [AIThinkingLength] {
        let effortOptions = openAIEfforts.compactMap { effort -> AIThinkingLength? in
            switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "none", "off", "disabled":
                .off
            case "minimal":
                .openAIMinimal
            case "low":
                .openAILow
            case "medium":
                .openAIMedium
            case "high":
                .openAIHigh
            case "xhigh", "x-high":
                .openAIXHigh
            default:
                nil
            }
        }

        let budgetOptions = thinkingBudgets.sorted().compactMap { budget -> AIThinkingLength? in
            switch budget {
            case 0:
                .off
            case 1...128:
                .providerShort
            case 129...512:
                .providerMedium
            case 513...:
                .providerLong
            default:
                nil
            }
        }

        return (effortOptions + budgetOptions).uniqued()
    }

    static func isProviderThinkingModel(model: String, endpoint: String) -> Bool {
        model.contains("qwen")
    }

    static func isOpenAIReasoningModel(_ model: String) -> Bool {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedModel.hasPrefix("gpt-5")
            || normalizedModel.hasPrefix("o1")
            || normalizedModel.hasPrefix("o3")
            || normalizedModel.hasPrefix("o4")
    }
}
