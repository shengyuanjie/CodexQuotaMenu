import Foundation

// Mirrors the desktop's default projectless layout; allocate only when delivery starts.
enum ScheduledMessageWorkspace {
    static func defaultRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Documents/Codex", isDirectory: true)
    }

    static func create(root: URL, message: String, date: Date, calendar: Calendar = .current) throws -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let parent = root.appendingPathComponent(day, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let expression = try NSRegularExpression(pattern: "[a-z0-9]+")
        let lower = message.lowercased() as NSString
        let words = expression.matches(in: lower as String, range: NSRange(location: 0, length: lower.length))
            .prefix(6).map { lower.substring(with: $0.range) }
        let name = words.isEmpty ? "new-chat" : String(words.joined(separator: "-").prefix(80))
        for index in 1...100 {
            let directory = parent.appendingPathComponent(index == 1 ? name : "\(name)-\(index)", isDirectory: true)
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain,
                   (error as NSError).code == NSFileWriteFileExistsError { continue }
                throw error
            }
            try fm.createDirectory(at: directory.appendingPathComponent("work"), withIntermediateDirectories: false)
            try fm.createDirectory(at: directory.appendingPathComponent("outputs"), withIntermediateDirectories: false)
            return directory
        }
        throw ScheduledMessageError.collision
    }
}
