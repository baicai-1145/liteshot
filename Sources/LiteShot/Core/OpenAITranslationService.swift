import Foundation

@MainActor
final class OpenAITranslationService {
    private static let directBatchLineLimit = 64
    private static let concurrentBatchLineLimit = 32
    private static let maxConcurrentRequests = 4

    private let settings: AppSettings
    private let session: URLSession

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func translate(_ text: String) async throws -> String {
        let config = try requestConfig()
        return try await responseText(
            config: config,
            session: session,
            instructions: "Translate the user's text into \(config.targetLanguage). Preserve line breaks. Return only the translation.",
            input: text
        )
    }

    func translateLines(_ lines: [OCRTextLine], progress: ((Int, Int) -> Void)? = nil) async throws -> [TranslatedTextLine] {
        let total = lines.count
        guard total > 0 else { return [] }

        let config = try requestConfig()
        let session = session
        var translatedByID: [Int: String] = [:]

        if lines.count <= Self.directBatchLineLimit {
            let translatedBatch = try await translateLineBatch(lines, config: config, session: session)
            for line in translatedBatch {
                translatedByID[line.id] = line.text
            }
            progress?(total, total)
        } else {
            var completed = 0
            let batches = lines.chunked(maxCount: Self.concurrentBatchLineLimit)
            let maxConcurrentRequests = Self.maxConcurrentRequests

            try await withThrowingTaskGroup(of: [TranslationOutputLine].self) { group in
                var nextBatchIndex = 0

                func enqueueNextBatch() {
                    guard nextBatchIndex < batches.count else { return }
                    let batch = batches[nextBatchIndex]
                    nextBatchIndex += 1
                    group.addTask {
                        try await translateLineBatch(batch, config: config, session: session)
                    }
                }

                for _ in 0..<min(maxConcurrentRequests, batches.count) {
                    enqueueNextBatch()
                }

                while let translatedBatch = try await group.next() {
                    for line in translatedBatch {
                        translatedByID[line.id] = line.text
                    }
                    completed += translatedBatch.count
                    progress?(min(completed, total), total)
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
        let config = try requestConfig()
        guard let url = OpenAIEndpoint.modelsURL(from: config.url) else {
            throw TranslationError.invalidEndpoint
        }
        return try await fetchModelIDs(config: config, session: session, url: url)
    }

    private func requestConfig() throws -> TranslationRequestConfig {
        let apiKey = settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw TranslationError.missingAPIKey
        }

        let endpoint = settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint) else {
            throw TranslationError.invalidEndpoint
        }

        return TranslationRequestConfig(
            apiKey: apiKey,
            url: url,
            model: model,
            targetLanguage: settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines),
            endpointKind: OpenAIEndpoint.kind(for: url),
            thinkingLength: AIThinkingLength.normalized(settings.openAIThinkingLength, model: model, endpoint: endpoint),
            shouldSendProviderThinkingControls: Self.shouldSendProviderThinkingControls(model: settings.openAIModel, url: url)
        )
    }

    private static func shouldSendProviderThinkingControls(model: String, url: URL) -> Bool {
        let lowercasedModel = model.lowercased()
        return lowercasedModel.contains("qwen")
    }
}

struct TranslatedTextLine: Identifiable, Sendable, Equatable {
    let id: Int
    let sourceText: String
    let translatedText: String
    let boundingBox: CGRect
}

struct AIModelInfo: Identifiable, Sendable, Hashable {
    let id: String
    let reasoningOptions: [AIThinkingLength]?
}

enum TranslationError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "请先在偏好设置中填写 OpenAI API Key。"
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
