import CoreGraphics
import Foundation

@main
enum LiteShotAIHelper {
    static func main() async {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let request = try JSONDecoder().decode(AIHelperRequest.self, from: input)
            let service = AIHelperService(config: try request.config.requestConfig())

            switch request.command {
            case .translate:
                let text = try await service.translate(request.text ?? "")
                try writeJSON(AIHelperTextResponse(text: text))
            case .translateLines:
                let lines = try await service.translateLines(request.lines ?? [])
                try writeJSON(AIHelperTranslatedLinesResponse(lines: lines))
            case .fetchModels:
                let models = try await service.fetchModels()
                try writeJSON(AIHelperModelsResponse(models: models))
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        FileHandle.standardOutput.write(data)
    }
}

private final class AIHelperService {
    private static let directBatchLineLimit = 64
    private static let concurrentBatchLineLimit = 32
    private static let maxConcurrentRequests = 4

    private let config: TranslationRequestConfig
    private let session = URLSession.shared

    init(config: TranslationRequestConfig) {
        self.config = config
    }

    func translate(_ text: String) async throws -> String {
        try await responseText(
            config: config,
            session: session,
            instructions: "Translate the user's text into \(config.targetLanguage). Preserve line breaks. Return only the translation.",
            input: text
        )
    }

    func translateLines(_ lines: [OCRTextLine]) async throws -> [TranslatedTextLine] {
        let total = lines.count
        guard total > 0 else { return [] }

        var translatedByID: [Int: String] = [:]

        if lines.count <= Self.directBatchLineLimit {
            let translatedBatch = try await translateLineBatch(lines, config: config, session: session)
            for line in translatedBatch {
                translatedByID[line.id] = line.text
            }
        } else {
            let batches = lines.chunked(maxCount: Self.concurrentBatchLineLimit)
            let maxConcurrentRequests = Self.maxConcurrentRequests
            let requestConfig = self.config
            let requestSession = self.session

            try await withThrowingTaskGroup(of: [TranslationOutputLine].self) { group in
                var nextBatchIndex = 0

                func enqueueNextBatch() {
                    guard nextBatchIndex < batches.count else { return }
                    let batch = batches[nextBatchIndex]
                    nextBatchIndex += 1
                    group.addTask {
                        try await translateLineBatch(batch, config: requestConfig, session: requestSession)
                    }
                }

                for _ in 0..<min(maxConcurrentRequests, batches.count) {
                    enqueueNextBatch()
                }

                while let translatedBatch = try await group.next() {
                    for line in translatedBatch {
                        translatedByID[line.id] = line.text
                    }
                    enqueueNextBatch()
                }
            }
        }

        return lines.map { line in
            TranslatedTextLine(
                id: line.id,
                sourceText: line.text,
                translatedText: translatedByID[line.id]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? line.text,
                boundingBox: line.boundingBox
            )
        }
    }

    func fetchModels() async throws -> [AIModelInfo] {
        guard let url = OpenAIEndpoint.modelsURL(from: config.url) else {
            throw TranslationError.invalidEndpoint
        }
        return try await fetchModelIDs(config: config, session: session, url: url)
    }
}

private struct AIHelperRequest: Decodable {
    let command: AIHelperCommand
    let config: AIHelperConfig
    let text: String?
    let lines: [OCRTextLine]?
}

private enum AIHelperCommand: String, Decodable {
    case translate
    case translateLines
    case fetchModels
}

private struct AIHelperConfig: Codable {
    let apiKey: String
    let endpoint: String
    let model: String
    let targetLanguage: String
    let thinkingLength: String

    func requestConfig() throws -> TranslationRequestConfig {
        guard let url = URL(string: endpoint) else {
            throw TranslationError.invalidEndpoint
        }
        let thinkingLength = AIThinkingLength(rawValue: thinkingLength) ?? .off
        return TranslationRequestConfig(
            apiKey: apiKey,
            url: url,
            model: model,
            targetLanguage: targetLanguage,
            endpointKind: OpenAIEndpoint.kind(for: url),
            thinkingLength: AIThinkingLength.normalized(thinkingLength, model: model, endpoint: endpoint),
            shouldSendProviderThinkingControls: model.lowercased().contains("qwen")
        )
    }
}

private struct AIHelperTextResponse: Encodable {
    let text: String
}

private struct AIHelperTranslatedLinesResponse: Encodable {
    let lines: [TranslatedTextLine]
}

private struct AIHelperModelsResponse: Encodable {
    let models: [AIModelInfo]
}

private struct OCRTextLine: Identifiable, Sendable, Codable {
    let id: Int
    let text: String
    let boundingBox: CGRect
}

private struct TranslatedTextLine: Identifiable, Sendable, Codable {
    let id: Int
    let sourceText: String
    let translatedText: String
    let boundingBox: CGRect
}

private struct AIModelInfo: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let reasoningOptions: [AIThinkingLength]?
}

private enum TranslationError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "OpenAI API 地址无效。"
        case .requestFailed(let message):
            "翻译请求失败：\(message)"
        case .emptyResponse:
            "翻译接口没有返回文本。"
        }
    }
}

private struct TranslationRequestConfig: Sendable {
    let apiKey: String
    let url: URL
    let model: String
    let targetLanguage: String
    let endpointKind: OpenAIEndpointKind
    let thinkingLength: AIThinkingLength
    let shouldSendProviderThinkingControls: Bool
}

private func translateLineBatch(
    _ lines: [OCRTextLine],
    config: TranslationRequestConfig,
    session: URLSession
) async throws -> [TranslationOutputLine] {
    let inputData = try JSONEncoder().encode(lines.map(\.text))
    let input = String(data: inputData, encoding: .utf8) ?? "[]"
    let output = try await responseText(
        config: config,
        session: session,
        instructions: """
        Translate every string in the JSON array into \(config.targetLanguage).
        Preserve the input array length and order.
        Return only a compact strict JSON array of translated strings.
        Do not include markdown fences or commentary.
        """,
        input: input
    )

    if let translatedTexts = decodeTranslatedTextArray(from: output), translatedTexts.count == lines.count {
        return zip(lines, translatedTexts).map { line, translatedText in
            TranslationOutputLine(id: line.id, text: translatedText)
        }
    }

    if let translatedLines = decodeTranslatedLines(from: output), !translatedLines.isEmpty {
        return translatedLines
    }

    return fallbackTranslatedLines(from: output, sourceLines: lines)
}

private func responseText(
    config: TranslationRequestConfig,
    session: URLSession,
    instructions: String,
    input: String
) async throws -> String {
    switch config.endpointKind {
    case .responses:
        return try await responsesText(config: config, session: session, instructions: instructions, input: input)
    case .chatCompletions:
        return try await chatCompletionsText(config: config, session: session, instructions: instructions, input: input)
    }
}

private func responsesText(
    config: TranslationRequestConfig,
    session: URLSession,
    instructions: String,
    input: String
) async throws -> String {
    var request = URLRequest(url: config.url)
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let thinkingControls = providerThinkingControls(for: config)
    let body = ResponsesRequest(
        model: config.model,
        instructions: instructions,
        input: input,
        enableThinking: thinkingControls?.enableThinking,
        thinkingBudget: thinkingControls?.thinkingBudget,
        reasoning: openAIReasoning(for: config)
    )
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw TranslationError.requestFailed(message)
    }

    let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
    if let outputText = decoded.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
        return outputText
    }

    let fallback = decoded.output?
        .flatMap { $0.content ?? [] }
        .compactMap(\.text)
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let fallback, !fallback.isEmpty else {
        throw TranslationError.emptyResponse
    }
    return fallback
}

private func chatCompletionsText(
    config: TranslationRequestConfig,
    session: URLSession,
    instructions: String,
    input: String
) async throws -> String {
    var request = URLRequest(url: config.url)
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let thinkingControls = providerThinkingControls(for: config)
    let body = ChatCompletionsRequest(
        model: config.model,
        messages: [
            ChatMessage(role: "system", content: instructions),
            ChatMessage(role: "user", content: input)
        ],
        temperature: 0,
        enableThinking: thinkingControls?.enableThinking,
        thinkingBudget: thinkingControls?.thinkingBudget,
        reasoningEffort: openAIReasoningEffort(for: config)
    )
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw TranslationError.requestFailed(message)
    }

    let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
    let text = decoded.choices
        .compactMap(\.message?.content)
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        throw TranslationError.emptyResponse
    }
    return text
}

private func fetchModelIDs(config: TranslationRequestConfig, session: URLSession, url: URL) async throws -> [AIModelInfo] {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 60
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
        throw TranslationError.requestFailed(message)
    }

    let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
    let modelIDs = decoded.data
        .map { item in
            AIModelInfo(
                id: item.id.trimmingCharacters(in: .whitespacesAndNewlines),
                reasoningOptions: item.reasoningOptions
            )
        }
        .filter { !$0.id.isEmpty }
        .uniquedByID()
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

    guard !modelIDs.isEmpty else {
        throw TranslationError.requestFailed("模型列表为空。")
    }
    return modelIDs
}

private func providerThinkingControls(for config: TranslationRequestConfig) -> ProviderThinkingControls? {
    guard config.shouldSendProviderThinkingControls else { return nil }
    return ProviderThinkingControls(
        enableThinking: config.thinkingLength.isThinkingEnabled,
        thinkingBudget: config.thinkingLength.thinkingBudget
    )
}

private func openAIReasoning(for config: TranslationRequestConfig) -> OpenAIReasoning? {
    guard let effort = openAIReasoningEffort(for: config) else { return nil }
    return OpenAIReasoning(effort: effort)
}

private func openAIReasoningEffort(for config: TranslationRequestConfig) -> String? {
    guard AIThinkingLength.isOpenAIReasoningModel(config.model) else { return nil }
    return config.thinkingLength.openAIReasoningEffort
}

private struct ProviderThinkingControls {
    let enableThinking: Bool
    let thinkingBudget: Int?
}

private struct TranslationOutputLine: Decodable, Sendable {
    let id: Int
    let text: String
}

private struct ResponsesRequest: Encodable, Sendable {
    let model: String
    let instructions: String
    let input: String
    let enableThinking: Bool?
    let thinkingBudget: Int?
    let reasoning: OpenAIReasoning?

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case reasoning
    }
}

private struct OpenAIReasoning: Encodable, Sendable {
    let effort: String
}

private struct ChatCompletionsRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let enableThinking: Bool?
    let thinkingBudget: Int?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case reasoningEffort = "reasoning_effort"
    }
}

private struct ChatMessage: Encodable, Sendable {
    let role: String
    let content: String
}

private struct ChatCompletionsResponse: Decodable, Sendable {
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable, Sendable {
    let message: ChatResponseMessage?
}

private struct ChatResponseMessage: Decodable, Sendable {
    let content: String?
}

private struct ModelsResponse: Decodable, Sendable {
    let data: [ModelItem]
}

private struct ModelItem: Decodable, Sendable {
    let id: String
    let reasoningOptions: [AIThinkingLength]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        id = try container.decode(String.self, forKey: DynamicCodingKey("id"))

        let openAIEfforts = Self.collectStringOptions(from: container)
        let thinkingBudgets = Self.collectIntOptions(from: container)
        let options = AIThinkingLength.options(openAIEfforts: openAIEfforts, thinkingBudgets: thinkingBudgets)
        reasoningOptions = options.isEmpty ? nil : options
    }

    private static func collectStringOptions(from container: KeyedDecodingContainer<DynamicCodingKey>) -> [String] {
        let keys = [
            "reasoning_efforts",
            "supported_reasoning_efforts",
            "reasoning_effort_options",
            "supported_reasoning_effort_options",
            "reasoning_options",
            "efforts"
        ]
        var values = keys.flatMap { decodeStringArray(from: container, key: $0) }
        for nestedKey in ["reasoning", "capabilities", "metadata"] {
            guard let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: DynamicCodingKey(nestedKey)) else {
                continue
            }
            values.append(contentsOf: keys.flatMap { decodeStringArray(from: nested, key: $0) })
        }
        return values
    }

    private static func collectIntOptions(from container: KeyedDecodingContainer<DynamicCodingKey>) -> [Int] {
        let keys = [
            "thinking_budgets",
            "supported_thinking_budgets",
            "thinking_budget_options",
            "supported_thinking_budget_options",
            "budgets"
        ]
        var values = keys.flatMap { decodeIntArray(from: container, key: $0) }
        for nestedKey in ["thinking", "reasoning", "capabilities", "metadata"] {
            guard let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: DynamicCodingKey(nestedKey)) else {
                continue
            }
            values.append(contentsOf: keys.flatMap { decodeIntArray(from: nested, key: $0) })
        }
        return values
    }

    private static func decodeStringArray(from container: KeyedDecodingContainer<DynamicCodingKey>, key: String) -> [String] {
        (try? container.decode([String].self, forKey: DynamicCodingKey(key))) ?? []
    }

    private static func decodeIntArray(from container: KeyedDecodingContainer<DynamicCodingKey>, key: String) -> [Int] {
        (try? container.decode([Int].self, forKey: DynamicCodingKey(key))) ?? []
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension Array where Element == AIModelInfo {
    func uniquedByID() -> [AIModelInfo] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

private struct ResponsesResponse: Decodable, Sendable {
    let outputText: String?
    let output: [OutputItem]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }
}

private struct OutputItem: Decodable, Sendable {
    let content: [ContentItem]?
}

private struct ContentItem: Decodable, Sendable {
    let text: String?
}

private func decodeTranslatedTextArray(from output: String) -> [String]? {
    let jsonString = jsonArrayPayload(from: output)
    guard let data = jsonString.data(using: .utf8) else {
        return nil
    }

    return try? JSONDecoder().decode([String].self, from: data)
}

private func decodeTranslatedLines(from output: String) -> [TranslationOutputLine]? {
    let jsonString = jsonArrayPayload(from: output)
    guard let data = jsonString.data(using: .utf8) else {
        return nil
    }

    return try? JSONDecoder().decode([TranslationOutputLine].self, from: data)
}

private func jsonArrayPayload(from output: String) -> String {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if let range = trimmed.range(of: #"(?s)\[.*\]"#, options: .regularExpression) {
        return String(trimmed[range])
    }
    return trimmed
}

private func fallbackTranslatedLines(from output: String, sourceLines: [OCRTextLine]) -> [TranslationOutputLine] {
    let rawLines = output
        .components(separatedBy: .newlines)
        .map { line in
            line.replacingOccurrences(of: #"^\s*(?:[-*]\s*)?(?:\d+[\).:：]\s*)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

    guard !rawLines.isEmpty else {
        return sourceLines.map { TranslationOutputLine(id: $0.id, text: $0.text) }
    }

    return sourceLines.enumerated().map { index, source in
        TranslationOutputLine(id: source.id, text: rawLines.indices.contains(index) ? rawLines[index] : source.text)
    }
}

private enum OpenAIEndpointKind: Sendable {
    case responses
    case chatCompletions
}

private enum OpenAIEndpoint {
    static func kind(for url: URL) -> OpenAIEndpointKind {
        let path = url.path.lowercased()
        if path.hasSuffix("/chat/completions") {
            return .chatCompletions
        }
        return .responses
    }

    static func modelsURL(from url: URL) -> URL? {
        endpointURL(from: url, leafPath: "models")
    }

    private static func endpointURL(from url: URL, leafPath: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        components.path = "\(v1Path(from: components.path))/\(leafPath)"
        return components.url
    }

    private static func v1Path(from path: String) -> String {
        let parts = path
            .split(separator: "/")
            .map(String.init)
        if let v1Index = parts.firstIndex(where: { $0.lowercased() == "v1" }) {
            return "/" + parts[...v1Index].joined(separator: "/")
        }
        return "/v1"
    }
}

private enum AIThinkingLength: String, CaseIterable, Sendable, Codable {
    case off
    case providerShort = "short"
    case providerMedium = "medium"
    case providerLong = "long"
    case openAIMinimal = "openai_minimal"
    case openAILow = "openai_low"
    case openAIMedium = "openai_medium"
    case openAIHigh = "openai_high"
    case openAIXHigh = "openai_xhigh"

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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    func chunked(maxCount: Int) -> [[Element]] {
        guard maxCount > 0, !isEmpty else { return [] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let nextIndex = Swift.min(index + maxCount, endIndex)
            result.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }
        return result
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
