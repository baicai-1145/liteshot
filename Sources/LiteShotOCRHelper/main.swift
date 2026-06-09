import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

struct OCRTextLine: Identifiable, Sendable, Equatable, Codable {
    let id: Int
    let text: String
    let boundingBox: CGRect
}

enum OCRHelperError: LocalizedError {
    case missingImagePath
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .missingImagePath:
            "缺少图片路径。"
        case .imageConversionFailed:
            "无法读取图片内容用于 OCR。"
        }
    }
}

@main
enum LiteShotOCRHelper {
    static func main() async {
        do {
            let lines = try await recognizeTextLines()
            let data = try JSONEncoder().encode(lines)
            FileHandle.standardOutput.write(data)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func recognizeTextLines() async throws -> [OCRTextLine] {
        guard let imagePath = CommandLine.arguments.dropFirst().first else {
            throw OCRHelperError.missingImagePath
        }
        let imageURL = URL(fileURLWithPath: imagePath)
        guard
            let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw OCRHelperError.imageConversionFailed
        }
        return try await performTextLineRecognition(in: cgImage)
    }

    private static func performTextLineRecognition(in cgImage: CGImage) async throws -> [OCRTextLine] {
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
