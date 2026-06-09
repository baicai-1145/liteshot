import Foundation

@MainActor
final class OpenAITranslationService {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func translate(_ text: String) async throws -> String {
        let config = try requestConfig()
        let response: AIHelperTextResponse = try await runAIHelper(
            AIHelperRequest(command: .translate, config: config, text: text, lines: nil)
        )
        return response.text
    }

    func translateLines(_ lines: [OCRTextLine], progress: ((Int, Int) -> Void)? = nil) async throws -> [TranslatedTextLine] {
        guard !lines.isEmpty else { return [] }
        let config = try requestConfig()
        let response: AIHelperTranslatedLinesResponse = try await runAIHelper(
            AIHelperRequest(command: .translateLines, config: config, text: nil, lines: lines)
        )
        progress?(lines.count, lines.count)
        return response.lines
    }

    func fetchModels() async throws -> [AIModelInfo] {
        let config = try requestConfig()
        let response: AIHelperModelsResponse = try await runAIHelper(
            AIHelperRequest(command: .fetchModels, config: config, text: nil, lines: nil)
        )
        return response.models
    }

    private func requestConfig() throws -> AIHelperConfig {
        settings.loadOpenAIAPIKeyIfNeeded()
        let apiKey = settings.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw TranslationError.missingAPIKey
        }

        let endpoint = settings.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, URL(string: endpoint) != nil else {
            throw TranslationError.invalidEndpoint
        }

        return AIHelperConfig(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            targetLanguage: settings.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines),
            thinkingLength: AIThinkingLength.normalized(settings.openAIThinkingLength, model: model, endpoint: endpoint).rawValue
        )
    }

    private func runAIHelper<Response: Decodable>(_ request: AIHelperRequest) async throws -> Response {
        guard let helperURL = Self.helperURL() else {
            throw TranslationError.helperNotFound
        }

        let inputData = try JSONEncoder().encode(request)
        let outputData = try await runProcess(executableURL: helperURL, input: inputData)
        return try JSONDecoder().decode(Response.self, from: outputData)
    }

    private func runProcess(executableURL: URL, input: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let resolver = ContinuationResolver<Data>(continuation: continuation)
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let outputBuffer = LockedDataBuffer()
            let errorBuffer = LockedDataBuffer()

            process.executableURL = executableURL
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                outputBuffer.append(handle.availableData)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                errorBuffer.append(handle.availableData)
            }
            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                outputBuffer.append(outputPipe.fileHandleForReading.availableData)
                errorBuffer.append(errorPipe.fileHandleForReading.availableData)

                if process.terminationStatus == 0 {
                    resolver.resume(returning: outputBuffer.data())
                } else {
                    let message = String(data: errorBuffer.data(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    resolver.resume(throwing: TranslationError.helperFailed(message))
                }
            }

            do {
                try process.run()
                inputPipe.fileHandleForWriting.write(input)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                resolver.resume(throwing: error)
            }
        }
    }

    private static func helperURL() -> URL? {
        if let appBundleURL = Bundle.main.bundleURL as URL?, appBundleURL.pathExtension == "app" {
            let helperURL = appBundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("LiteShotAIHelper")
            if FileManager.default.isExecutableFile(atPath: helperURL.path) {
                return helperURL
            }
        }

        if let executableURL = Bundle.main.executableURL {
            let siblingURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("LiteShotAIHelper")
            if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
                return siblingURL
            }
        }

        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for configuration in ["release", "debug"] {
            let helperURL = workingDirectory
                .appendingPathComponent(".build")
                .appendingPathComponent(configuration)
                .appendingPathComponent("LiteShotAIHelper")
            if FileManager.default.isExecutableFile(atPath: helperURL.path) {
                return helperURL
            }
        }

        return nil
    }
}

struct TranslatedTextLine: Identifiable, Sendable, Equatable, Codable {
    let id: Int
    let sourceText: String
    let translatedText: String
    let boundingBox: CGRect
}

struct AIModelInfo: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let reasoningOptions: [AIThinkingLength]?
}

enum TranslationError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case helperNotFound
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "请先在偏好设置中填写 OpenAI API Key。"
        case .invalidEndpoint:
            "OpenAI API 地址无效。"
        case .helperNotFound:
            "未找到 AI helper。请重新打包或重新安装 LiteShot。"
        case .helperFailed(let message):
            message.isEmpty ? "AI 请求失败。" : "AI 请求失败：\(message)"
        }
    }
}

private struct AIHelperRequest: Encodable {
    let command: AIHelperCommand
    let config: AIHelperConfig
    let text: String?
    let lines: [OCRTextLine]?
}

private enum AIHelperCommand: String, Encodable {
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
}

private struct AIHelperTextResponse: Decodable {
    let text: String
}

private struct AIHelperTranslatedLinesResponse: Decodable {
    let lines: [TranslatedTextLine]
}

private struct AIHelperModelsResponse: Decodable {
    let models: [AIModelInfo]
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ContinuationResolver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Value, Error>

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        guard markResumed() else { return }
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard markResumed() else { return }
        continuation.resume(throwing: error)
    }

    private func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}
