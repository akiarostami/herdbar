import Foundation

/// Reads what an agent last said from Claude Code's transcript of its session.
///
/// Transcripts are JSON lines in `~/.claude/projects/<folder>/<session id>.jsonl` and can be
/// hundreds of megabytes, so only the end of the file is read.
public enum Transcript {
    public struct Latest: Equatable, Sendable {
        /// The session's title: the name it was given with /rename, or else the short title
        /// Claude Code wrote for it.
        public var title: String?
        /// The start of the last thing the agent said.
        public var message: String?

        public init(title: String? = nil, message: String? = nil) {
            self.title = title
            self.message = message
        }
    }

    public static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// The transcript file for a session, looked for in every project folder.
    public static func file(sessionID: String, in directory: URL = projectsDirectory) -> URL? {
        guard !sessionID.isEmpty, sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let folders = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for folder in folders {
            let candidate = folder.appendingPathComponent(sessionID + ".jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The session's title and last message, from the last `tailBytes` of the file; if the
    /// message is not in there, from a tail eight times as long.
    public static func latest(in file: URL, tailBytes: Int = 512 * 1024, messageLimit: Int = 240) -> Latest {
        var result = scan(file, tailBytes: tailBytes, messageLimit: messageLimit)
        if result.message == nil {
            let wider = scan(file, tailBytes: tailBytes * 8, messageLimit: messageLimit)
            result = Latest(title: result.title ?? wider.title, message: wider.message)
        }
        return result
    }

    private static func scan(_ file: URL, tailBytes: Int, messageLimit: Int) -> Latest {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Latest() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return Latest() }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // the first line is probably cut

        // Claude Code keeps writing both titles near the end of the file, so the tail holds
        // them. A name given with /rename wins over Claude's own title.
        var latest = Latest()
        var customTitle: String?
        var aiTitle: String?
        for line in lines.reversed() {
            if customTitle != nil, latest.message != nil { break }
            // Cheap checks first: most lines are neither a title nor an assistant message.
            let isCustom = line.range(of: Data(#""type":"custom-title""#.utf8)) != nil
            let isAI = line.range(of: Data(#""type":"ai-title""#.utf8)) != nil
            let isAssistant = line.range(of: Data(#""type":"assistant""#.utf8)) != nil
            guard (isCustom && customTitle == nil) || (isAI && aiTitle == nil) || (isAssistant && latest.message == nil),
                  let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "custom-title":
                if customTitle == nil, let title = entry["customTitle"] as? String, !title.isEmpty {
                    customTitle = title
                }
            case "ai-title":
                if aiTitle == nil, let title = entry["aiTitle"] as? String, !title.isEmpty {
                    aiTitle = title
                }
            case "assistant":
                // Skip subagents' messages, which share the file.
                guard latest.message == nil, entry["isSidechain"] as? Bool != true,
                      let message = entry["message"] as? [String: Any],
                      let parts = message["content"] as? [[String: Any]] else { continue }
                let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: " ")
                let excerpt = Transcript.excerpt(text, limit: messageLimit)
                if !excerpt.isEmpty { latest.message = excerpt }
            default:
                continue
            }
        }
        latest.title = customTitle ?? aiTitle
        return latest
    }

    /// One line of plain text: Markdown marks dropped, spaces collapsed, cut at `limit` characters.
    public static func excerpt(_ text: String, limit: Int) -> String {
        var plain = text
        for mark in ["**", "__", "`", "### ", "## ", "# "] {
            plain = plain.replacingOccurrences(of: mark, with: "")
        }
        let words = plain.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        plain = words.joined(separator: " ")
        guard plain.count > limit else { return plain }
        return String(plain.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
