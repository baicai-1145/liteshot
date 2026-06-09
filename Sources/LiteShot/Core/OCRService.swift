import AppKit
import Foundation

enum OCRServiceError: LocalizedError {
    case imageConversionFailed
    case helperNotFound
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            "无法读取图片内容用于 OCR。"
        case .helperNotFound:
            "未找到 OCR helper。请重新打包或重新安装 LiteShot。"
        case .helperFailed(let message):
            message.isEmpty ? "OCR 识别失败。" : "OCR 识别失败：\(message)"
        }
    }
}

struct OCRTextLine: Identifiable, Sendable, Equatable, Codable {
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

    func recognizeText(in image: CapturedImage) async throws -> String {
        try await recognizeTextLines(in: image)
            .map(\.text)
            .joined(separator: "\n")
    }

    func recognizeTextLines(in image: NSImage) async throws -> [OCRTextLine] {
        let imageURL = try writeTemporaryImage(image)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let data = try await runOCRHelper(imageURL: imageURL)
        return try JSONDecoder().decode([OCRTextLine].self, from: data)
    }

    func recognizeTextLines(in image: CapturedImage) async throws -> [OCRTextLine] {
        let imageURL = try writeTemporaryImage(image)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let data = try await runOCRHelper(imageURL: imageURL)
        return try JSONDecoder().decode([OCRTextLine].self, from: data)
    }

    private func writeTemporaryImage(_ image: NSImage) throws -> URL {
        guard let pngData = autoreleasepool(invoking: { ImageExporter.encodedData(for: image, format: .png) }) else {
            throw OCRServiceError.imageConversionFailed
        }
        return try writeTemporaryPNGData(pngData)
    }

    private func writeTemporaryImage(_ image: CapturedImage) throws -> URL {
        guard let pngData = autoreleasepool(invoking: { ImageExporter.encodedData(for: image, format: .png) }) else {
            throw OCRServiceError.imageConversionFailed
        }
        return try writeTemporaryPNGData(pngData)
    }

    private func writeTemporaryPNGData(_ pngData: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiteShot-OCR-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try pngData.write(to: url, options: [.atomic])
        return url
    }

    private func runOCRHelper(imageURL: URL) async throws -> Data {
        guard let helperURL = Self.helperURL() else {
            throw OCRServiceError.helperNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resolver = ContinuationResolver<Data>(continuation: continuation)
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let outputBuffer = LockedDataBuffer()
            let errorBuffer = LockedDataBuffer()
            process.executableURL = helperURL
            process.arguments = [imageURL.path]
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
                    resolver.resume(throwing: OCRServiceError.helperFailed(message))
                }
            }

            do {
                try process.run()
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
                .appendingPathComponent("LiteShotOCRHelper")
            if FileManager.default.isExecutableFile(atPath: helperURL.path) {
                return helperURL
            }
        }

        if let executableURL = Bundle.main.executableURL {
            let siblingURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("LiteShotOCRHelper")
            if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
                return siblingURL
            }
        }

        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for configuration in ["release", "debug"] {
            let helperURL = workingDirectory
                .appendingPathComponent(".build")
                .appendingPathComponent(configuration)
                .appendingPathComponent("LiteShotOCRHelper")
            if FileManager.default.isExecutableFile(atPath: helperURL.path) {
                return helperURL
            }
        }

        return nil
    }
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
