import Foundation

/// Reads the line-by-line output of `herdr-core events --json`.
///
/// The first line is a snapshot: `{"seq": …, "terminals": [ … ]}`. Later lines are JSON-RPC
/// notifications: a `heartbeat`, or an `event` about one terminal, of which `status` events
/// carry the terminal's new status.
public enum HerdrFeed {
    public enum Line: Equatable, Sendable {
        case snapshot([Agent])
        /// A terminal's status changed. `message` and `kind` are nil when the event has none.
        case status(address: String, status: String, kind: String?, message: String?)
        /// Something else about a terminal changed (a label, its title, it started or ended).
        case other(address: String?)
        case heartbeat
    }

    public static func parse(_ line: String, now: Date = Date()) -> Line? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let terminals = object["terminals"] as? [[String: Any]] {
            return .snapshot(named(terminals.compactMap(agent), among: terminals))
        }
        guard let method = object["method"] as? String else { return nil }
        if method == "heartbeat" { return .heartbeat }
        guard method == "event", let params = object["params"] as? [String: Any] else { return nil }
        let address = params["terminal"] as? String
        if params["type"] as? String == "status", let address,
           let data = params["data"] as? [String: Any], let status = data["status"] as? [String: Any],
           let state = status["state"] as? String {
            return .status(address: address, status: state, kind: status["kind"] as? String,
                           message: status["msg"] as? String)
        }
        return .other(address: address)
    }

    /// Names agents the way Herdr's own list does: an agent alone in its tab goes by the tab's
    /// name ("lead", "architect"); agents sharing a tab go by their terminal titles ("coder1").
    static func named(_ agents: [Agent], among terminals: [[String: Any]]) -> [Agent] {
        var perTab: [String: Int] = [:]
        for terminal in terminals where (terminal["state"] as? String ?? "live") == "live" {
            let labels = terminal["labels"] as? [String: Any] ?? [:]
            let (space, tab) = place(labels["where"] as? String, cwd: terminal["cwd"] as? String)
            perTab["\(space)\u{1}\(tab)", default: 0] += 1
        }
        return agents.map { agent in
            guard !agent.tab.isEmpty, perTab["\(agent.space)\u{1}\(agent.tab)"] == 1 else { return agent }
            var agent = agent
            agent.name = agent.tab
            return agent
        }
    }

    /// A terminal that is running an agent; nil for plain shells and finished terminals.
    static func agent(_ terminal: [String: Any]) -> Agent? {
        guard let address = terminal["address"] as? String,
              (terminal["state"] as? String ?? "live") == "live",
              let status = terminal["status"] as? [String: Any],
              let state = status["state"] as? String else { return nil }
        let labels = terminal["labels"] as? [String: Any] ?? [:]
        let (space, tab) = place(labels["where"] as? String, cwd: terminal["cwd"] as? String)
        let title = (terminal["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let changed = (terminal["status_ms"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Agent(address: address,
                     name: title ?? (terminal["name"] as? String) ?? address,
                     space: space, tab: tab,
                     app: status["app"] as? String ?? "agent",
                     status: state, kind: status["kind"] as? String, message: status["msg"] as? String,
                     statusChanged: changed,
                     turn: (terminal["turn"] as? Int) ?? 0,
                     seenTurn: (labels["herdr.seen"] as? String).flatMap { Int($0) },
                     sessionID: sessionID(labels["hako.agent-session"] as? String),
                     spaceID: labels["herdr.space"] as? String, tabID: labels["herdr.tab"] as? String)
    }

    /// The session ID inside the label Herdr keeps as JSON: {"agent": "claude", "session": "…"}.
    static func sessionID(_ label: String?) -> String? {
        guard let data = label?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["session"] as? String
    }

    /// "Storefront / lead" is space "Storefront", tab "lead". Without that label, the folder's name.
    static func place(_ whereLabel: String?, cwd: String?) -> (space: String, tab: String) {
        if let whereLabel, !whereLabel.isEmpty {
            let parts = whereLabel.components(separatedBy: " / ")
            let space = parts[0].trimmingCharacters(in: .whitespaces)
            let tab = parts.dropFirst().joined(separator: " / ").trimmingCharacters(in: .whitespaces)
            if !space.isEmpty { return (space, tab) }
        }
        let folder = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return (folder.isEmpty ? "Other" : folder, "")
    }

    /// Applies a status event to the list. Unknown addresses are left for the next snapshot.
    public static func apply(_ line: Line, to agents: [Agent], now: Date = Date()) -> [Agent] {
        guard case let .status(address, status, kind, message) = line,
              let index = agents.firstIndex(where: { $0.address == address }) else { return agents }
        var agents = agents
        if agents[index].status != status {
            agents[index].statusChanged = now
        }
        agents[index].status = status
        agents[index].kind = kind
        agents[index].message = message
        return agents
    }
}

/// Something worth telling the user: an agent started needing them, or finished.
public struct Notice: Identifiable, Equatable, Sendable {
    public var agent: Agent
    /// Claude's short title for the session, and the start of what the agent last said,
    /// when its transcript could be read.
    public var headline: String?
    public var excerpt: String?
    public var id: String { "\(agent.address):\(agent.state.rawValue):\(agent.turn)" }

    public init(agent: Agent, headline: String? = nil, excerpt: String? = nil) {
        self.agent = agent
        self.headline = headline
        self.excerpt = excerpt
    }

    public var title: String { "\(agent.space) · \(agent.name)" }

    /// What happened, in a few words: "Finished", "Needs permission".
    public var event: String { agent.detail }

    /// What happened, then what the agent said, for places with a single body text.
    public var body: String {
        [event, excerpt].compactMap { $0 }.joined(separator: " — ")
    }
}

public enum Notices {
    /// The agents that moved into Needs you or Done between two readings. Agents that are
    /// new in `new` do not count: on first sight their state is old news.
    public static func between(old: [Agent], new: [Agent], muted: Set<String>) -> [Notice] {
        let before = Dictionary(old.map { ($0.address, $0.state) }, uniquingKeysWith: { a, _ in a })
        return new.compactMap { agent in
            guard let was = before[agent.address], was != agent.state,
                  agent.state == .needsYou || agent.state == .done,
                  !muted.contains(agent.muteKey) else { return nil }
            return Notice(agent: agent)
        }
    }
}
