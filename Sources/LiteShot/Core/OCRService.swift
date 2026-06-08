import AppKit
@preconcurrency import Vision

enum OCRServiceError: LocalizedError {
    case imageConversionFailed

    var errorDescription: String? {
        "无法读取图片内容用于 OCR。"
    }
}

struct OCRTextLine: Identifiable, Sendable, Equatable {
    let id: Int
    let text: String
    let boundingBox: CGRect
}

@MainActor
final class OCRService {
    func recognizeText(in image: NSImage) async throws -> String {
        try await recognizeTextLines(in: image)
            .map(\.text)
            .joined(separator: "\n")
    }

    func recognizeTextLines(in image: NSImage) async throws -> [OCRTextLine] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRServiceError.imageConversionFailed
        }

        return try await performTextLineRecognition(in: cgImage)
    }
}

private func performTextLineRecognition(in cgImage: CGImage) async throws -> [OCRTextLine] {
    try await withCheckedThrowingContinuation { continuation in
        let resolver = ContinuationResolver<[OCRTextLine]>(continuation: continuation)
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                resolver.resume(throwing: error)
                return
            }

            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let lines = observations
                .sorted { first, second in
                    if abs(first.boundingBox.midY - second.boundingBox.midY) > 0.015 {
                        return first.boundingBox.midY > second.boundingBox.midY
                    }
                    return first.boundingBox.minX < second.boundingBox.minX
                }
                .enumerated()
                .compactMap { index, observation -> OCRTextLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return OCRTextLine(id: index, text: text, boundingBox: observation.boundingBox)
                }
            resolver.resume(returning: lines)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        if let supportedLanguages = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = preferredLanguages.filter { supportedLanguages.contains($0) }
        } else {
            request.recognitionLanguages = preferredLanguages
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                resolver.resume(throwing: error)
            }
        }
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
