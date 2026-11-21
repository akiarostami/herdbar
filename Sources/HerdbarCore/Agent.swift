import Foundation

/// What an agent needs from you, in the order the app sorts by.
public enum AgentState: Int, Codable, Comparable, Sendable, CaseIterable {
    /// Blocked on a permission, a question or a sign-in, or stopped on an error.
    case needsYou
    /// Finished a turn you have not looked at yet.
    case done
    case working
    /// Idle, or finished and already seen.
    case idle

    public static func < (a: AgentState, b: AgentState) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .done: return "Done"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }
}

/// One agent running in a Herdr terminal.
public struct Agent: Identifiable, Hashable, Codable, Sendable {
    /// Herdr's address for the terminal, such as "t7".
    public var address: String
    /// The agent's name: the terminal's title.
    public var name: String
    public var space: String
    public var tab: String
    /// The program, such as "claude-code".
    public var app: String
    /// Herdr's own status word: idle, working, done, blocked or error.
    public var status: String
    /// Why it is blocked: permission, question or auth.
    public var kind: String?
    /// The agent's own words about what it is doing.
    public var message: String?
    public var statusChanged: Date?
    /// How many turns it has finished, and how many of those you have seen.
    public var turn: Int
    public var seenTurn: Int?
    /// The Claude Code session running in the terminal, for finding its transcript.
    public var sessionID: String?
    /// Herdr's identifiers for the space and tab the terminal is in.
    public var spaceID: String?
    public var tabID: String?

    public var id: String { address }

    public init(address: String, name: String, space: String, tab: String, app: String, status: String,
                kind: String? = nil, message: String? = nil, statusChanged: Date? = nil, turn: Int = 0, seenTurn: Int? = nil,
                sessionID: String? = nil, spaceID: String? = nil, tabID: String? = nil) {
        self.address = address
        self.name = name
        self.space = space
        self.tab = tab
        self.app = app
        self.status = status
        self.kind = kind
        self.message = message
        self.statusChanged = statusChanged
        self.turn = turn
        self.seenTurn = seenTurn
        self.sessionID = sessionID
        self.spaceID = spaceID
        self.tabID = tabID
    }

    /// Herdr's "done" becomes Done only while the finished turn is unseen; after that the
    /// agent is idle, as in Herdr's own list.
    public var state: AgentState {
        switch status {
        case "blocked", "error": return .needsYou
        case "working": return .working
        case "done": return turn > (seenTurn ?? turn) ? .done : .idle
        default: return .idle
        }
    }

    /// What identifies the agent across Herdr restarts, when addresses change: its space and name.
    public var muteKey: String { "\(space)/\(name)" }

    /// One line on what it is doing or waiting for.
    public var detail: String {
        switch state {
        case .needsYou:
            switch (status, kind) {
            case ("error", _): return message.flatMap(nonEmpty) ?? "Stopped on an error"
            case (_, "permission"): return "Needs permission"
            case (_, "question"): return "Has a question"
            case (_, "auth"): return "Needs you to sign in"
            default: return message.flatMap(nonEmpty) ?? "Waiting for you"
            }
        case .done: return "Finished"
        case .working: return message.flatMap(nonEmpty) ?? "Working"
        case .idle: return "Idle"
        }
    }

    private func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// How many agents are in each state.
public struct Counts: Equatable, Sendable {
    public var needsYou = 0
    public var done = 0
    public var working = 0
    public var idle = 0

    public init(_ agents: [Agent] = []) {
        for agent in agents {
            switch agent.state {
            case .needsYou: needsYou += 1
            case .done: done += 1
            case .working: working += 1
            case .idle: idle += 1
            }
        }
    }

    public var total: Int { needsYou + done + working + idle }
}

/// The agents of one Herdr space, most urgent first.
public struct SpaceGroup: Identifiable, Equatable, Sendable {
    public var name: String
    public var agents: [Agent]
    public var id: String { name }
    public var counts: Counts { Counts(agents) }

    /// The most urgent state among its agents.
    public var state: AgentState { agents.map(\.state).min() ?? .idle }
}

/// The agents in one state, most recently changed first.
public struct StateGroup: Identifiable, Equatable, Sendable {
    public var state: AgentState
    public var agents: [Agent]
    public var id: Int { state.rawValue }

    public init(state: AgentState, agents: [Agent]) {
        self.state = state
        self.agents = agents
    }
}

public enum Grouping {
    /// The order of the menu's sections: questions first, then working, then done, then idle.
    public static let menuOrder: [AgentState] = [.needsYou, .working, .done, .idle]

    /// Groups by state, in `menuOrder`, leaving out states nobody is in. Within a state the
    /// most recent change comes first; ties go by space, then name.
    public static func byState(_ agents: [Agent]) -> [StateGroup] {
        menuOrder.compactMap { state in
            let members = agents.filter { $0.state == state }.sorted { a, b in
                let (x, y) = (a.statusChanged ?? .distantPast, b.statusChanged ?? .distantPast)
                if x != y { return x > y }
                if a.space != b.space { return a.space.localizedStandardCompare(b.space) == .orderedAscending }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return members.isEmpty ? nil : StateGroup(state: state, agents: members)
        }
    }

    /// Groups by space. Spaces with something that needs you come first, then finished work,
    /// then working ones, then idle ones; ties go by name. Agents are ordered the same way.
    public static func bySpace(_ agents: [Agent]) -> [SpaceGroup] {
        Dictionary(grouping: agents, by: \.space)
            .map { name, members in
                SpaceGroup(name: name, agents: members.sorted {
                    $0.state != $1.state ? $0.state < $1.state
                        : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                })
            }
            .sorted {
                $0.state != $1.state ? $0.state < $1.state
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
}
