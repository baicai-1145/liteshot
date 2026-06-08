import Foundation

enum OpenAIEndpointKind: Sendable {
    case responses
    case chatCompletions
}

enum OpenAIEndpoint {
    static func kind(for url: URL) -> OpenAIEndpointKind {
        let path = url.path.lowercased()
        if path.hasSuffix("/chat/completions") {
            return .chatCompletions
        }
        return .responses
    }

    static func chatCompletionsURLString(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "https://api.openai.com/v1/chat/completions"
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard
            let url = URL(string: candidate),
            let chatURL = chatCompletionsURL(from: url)
        else {
            return rawValue
        }

        return chatURL.absoluteString
    }

    static func chatCompletionsURL(from url: URL) -> URL? {
        endpointURL(from: url, leafPath: "chat/completions")
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
