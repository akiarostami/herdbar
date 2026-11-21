import Foundation

/// Where a space and tab sit in the Herdr app's layout, counted from 1, which is how Herdr's
/// own shortcuts number them (Control-1 … 9 for spaces, Command-1 … 9 for tabs).
public enum HerdrLayout {
    public struct Position: Equatable, Sendable {
        public var space: Int
        /// Nil when the tab was not found in the space.
        public var tab: Int?
    }

    /// The Herdr app keeps its layout in herdr-core's documents file.
    public static var documentsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/herdr-core/default/docs.json")
    }

    /// Reads `{"herdr-app": {"value": {"spaces": [{"id", "tabs": [{"id"}]}]}}}`.
    public static func position(spaceID: String, tabID: String?, in data: Data) -> Position? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = root["herdr-app"] as? [String: Any],
              let value = app["value"] as? [String: Any],
              let spaces = value["spaces"] as? [[String: Any]],
              let spaceIndex = spaces.firstIndex(where: { $0["id"] as? String == spaceID }) else { return nil }
        let tabs = spaces[spaceIndex]["tabs"] as? [[String: Any]] ?? []
        let tabIndex = tabID.flatMap { id in tabs.firstIndex(where: { $0["id"] as? String == id }) }
        return Position(space: spaceIndex + 1, tab: tabIndex.map { $0 + 1 })
    }
}
