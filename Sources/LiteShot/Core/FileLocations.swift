import Foundation

enum FileLocations {
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("LiteShot", isDirectory: true)
    }

    static var historyFile: URL {
        applicationSupportDirectory.appendingPathComponent("history.json")
    }

    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
    }
}
