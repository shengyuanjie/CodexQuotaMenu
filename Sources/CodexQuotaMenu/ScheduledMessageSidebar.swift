import Foundation

// A native session in thread/list is not necessarily registered in desktop Chats.
// Read the desktop-owned registration; never modify its global state from this app.
enum ScheduledMessageSidebar {
    static func isRegistered(_ id: String, stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/.codex-global-state.json")) -> Bool {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (state["projectless-thread-ids"] as? [String])?.contains(id) == true
            || (state["thread-project-assignments"] as? [String: Any])?[id] != nil
    }

    static func chatURL(_ id: String) -> URL? {
        guard let id = UUID(uuidString: id)?.uuidString.lowercased() else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    static func needsRegistration(_ item: ScheduledMessage) -> Bool {
        item.isNewTask && item.state == .sent && !isRegistered(item.threadID)
    }
}
