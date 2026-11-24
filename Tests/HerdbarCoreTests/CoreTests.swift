import Foundation
import Testing
@testable import HerdbarCore

private let snapshot = #"""
{"channel":null,"seq":10,"terminals":[
 {"address":"t1","title":"lead","state":"live","turn":12,"status_ms":1795000000000,"cwd":"/work/shop",
  "labels":{"where":"Shop / lead","herdr.seen":"12"},"status":{"app":"claude-code","state":"done"}},
 {"address":"t2","title":"coder1","state":"live","turn":5,"status_ms":1795000001000,"cwd":"/work/shop",
  "labels":{"where":"Shop / agents","herdr.seen":"4"},"status":{"app":"claude-code","state":"done"}},
 {"address":"t3","title":"coder2","state":"live","turn":3,"cwd":"/work/shop",
  "labels":{"where":"Shop / agents","herdr.seen":"3"},"status":{"app":"claude-code","state":"working","msg":"Running the tests"}},
 {"address":"t4","title":"reviewer","state":"live","turn":1,"cwd":"/work/blog",
  "labels":{"where":"Blog / agents"},"status":{"app":"claude-code","state":"blocked","kind":"permission"}},
 {"address":"t5","title":"","state":"live","turn":0,"cwd":"/work/misc","labels":{},"status":null},
 {"address":"t6","title":"designer","state":"live","turn":2,"cwd":"/work/notes","labels":{},"status":{"app":"claude-code","state":"idle"}}
]}
"""#.replacingOccurrences(of: "\n", with: "")

private func agents() -> [Agent] {
    guard case let .snapshot(list)? = HerdrFeed.parse(snapshot) else { return [] }
    return list
}

@Suite struct FeedTests {
    @Test func snapshotBecomesAgents() {
        let list = agents()
        #expect(list.map(\.address) == ["t1", "t2", "t3", "t4", "t6"])  // the plain shell is left out
        #expect(list[0].name == "lead" && list[0].space == "Shop" && list[0].tab == "lead")
        #expect(list[1].name == "coder1" && list[2].name == "coder2")     // two share the tab: their own titles
        #expect(list[3].name == "agents")                                 // alone in its tab: the tab's name
        #expect(list[4].space == "notes" && list[4].tab == "")           // no label: the folder's name
        #expect(list[0].statusChanged == Date(timeIntervalSince1970: 1_795_000_000))
    }

    @Test func doneMeansUnseen() {
        let list = agents()
        #expect(list[0].state == .idle)      // done, and seen
        #expect(list[1].state == .done)      // done, one turn not seen
        #expect(list[2].state == .working)
        #expect(list[3].state == .needsYou)
        #expect(list[4].state == .idle)
        #expect(Counts(list) == { var c = Counts(); c.idle = 2; c.done = 1; c.working = 1; c.needsYou = 1; return c }())
    }

    @Test func detailLines() {
        let list = agents()
        #expect(list[2].detail == "Running the tests")
        #expect(list[3].detail == "Needs permission")
        #expect(list[1].detail == "Finished")
    }

    @Test func eventsAndHeartbeats() {
        #expect(HerdrFeed.parse(#"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":11}}"#) == .heartbeat)
        let status = HerdrFeed.parse(#"{"jsonrpc":"2.0","method":"event","params":{"data":{"records":{},"status":{"app":"claude-code","msg":"Editing","state":"working"}},"seq":12,"terminal":"t1","type":"status"}}"#)
        #expect(status == .status(address: "t1", status: "working", kind: nil, message: "Editing"))
        #expect(HerdrFeed.parse(#"{"jsonrpc":"2.0","method":"event","params":{"data":{},"seq":13,"terminal":"t2","type":"labels"}}"#) == .other(address: "t2"))
        #expect(HerdrFeed.parse("not json") == nil)
    }

    @Test func statusEventUpdatesOneAgent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = HerdrFeed.apply(.status(address: "t1", status: "working", kind: nil, message: "Editing"), to: agents(), now: now)
        #expect(updated[0].state == .working && updated[0].message == "Editing" && updated[0].statusChanged == now)
        #expect(updated[1] == agents()[1])
        // An address not in the list changes nothing.
        #expect(HerdrFeed.apply(.status(address: "t99", status: "working", kind: nil, message: nil), to: agents()) == agents())
    }
}

@Suite struct TranscriptTests {
    func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("herdbar-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func latestTitleAndMessage() throws {
        let url = try file([
            #"{"type":"ai-title","aiTitle":"Old title"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"An earlier answer."}]}}"#,
            #"{"type":"user","message":{"content":"next"}}"#,
            #"{"type":"ai-title","aiTitle":"Run sign-in checks"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"**Done.** The `email` errors\nare now linked."}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"A helper speaking."}]}}"#,
            #"{"type":"mode","mode":"default"}"#,
        ])
        let latest = Transcript.latest(in: url)
        #expect(latest == Transcript.Latest(title: "Run sign-in checks", message: "Done. The email errors are now linked."))
    }

    @Test func readsOnlyTheEndButWidensWhenNeeded() throws {
        let filler = Array(repeating: #"{"type":"mode","mode":"default","pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}"#, count: 40)
        let url = try file([#"{"type":"assistant","message":{"content":[{"type":"text","text":"Far back."}]}}"#] + filler)
        // A tail too short to hold the message still finds it in the wider second pass.
        #expect(Transcript.latest(in: url, tailBytes: 600).message == "Far back.")
        #expect(Transcript.latest(in: URL(fileURLWithPath: "/nonexistent.jsonl")) == Transcript.Latest())
    }

    @Test func excerptIsOneShortLine() {
        #expect(Transcript.excerpt("## Result\n\nAll   good.", limit: 50) == "Result All good.")
        #expect(Transcript.excerpt(String(repeating: "word ", count: 20), limit: 12) == "word word wo…")
    }

    @Test func findsTheFileAndReadsTheSessionLabel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("herdbar-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-work-shop"), withIntermediateDirectories: true)
        let path = root.appendingPathComponent("-work-shop/abc-123.jsonl")
        try "{}\n".write(to: path, atomically: true, encoding: .utf8)
        #expect(Transcript.file(sessionID: "abc-123", in: root)?.lastPathComponent == "abc-123.jsonl")
        #expect(Transcript.file(sessionID: "missing", in: root) == nil)
        #expect(Transcript.file(sessionID: "../etc", in: root) == nil)
        #expect(HerdrFeed.sessionID(#"{"agent":"claude","pid":1,"session":"abc-123"}"#) == "abc-123")
        #expect(HerdrFeed.sessionID(nil) == nil)
    }
}

@Suite struct LayoutTests {
    let docs = Data(#"{"herdr-app":{"version":3,"value":{"spaces":[{"id":"spA","tabs":[{"id":"tb1"},{"id":"tb2"}]},{"id":"spB","tabs":[{"id":"tb3"}]}]}}}"#.utf8)

    @Test func positionsCountFromOne() {
        #expect(HerdrLayout.position(spaceID: "spA", tabID: "tb2", in: docs) == HerdrLayout.Position(space: 1, tab: 2))
        #expect(HerdrLayout.position(spaceID: "spB", tabID: "tb3", in: docs) == HerdrLayout.Position(space: 2, tab: 1))
        #expect(HerdrLayout.position(spaceID: "spB", tabID: "gone", in: docs) == HerdrLayout.Position(space: 2, tab: nil))
        #expect(HerdrLayout.position(spaceID: "nope", tabID: nil, in: docs) == nil)
        #expect(HerdrLayout.position(spaceID: "spA", tabID: nil, in: Data("junk".utf8)) == nil)
    }

    @Test func agentsCarryTheirSpaceAndTabIdentifiers() {
        let line = #"{"seq":1,"terminals":[{"address":"t1","title":"lead","state":"live","turn":1,"labels":{"where":"Shop / lead","herdr.space":"spA","herdr.tab":"tb1"},"status":{"app":"claude-code","state":"idle"}}]}"#
        guard case let .snapshot(list)? = HerdrFeed.parse(line) else { Issue.record("no snapshot"); return }
        #expect(list[0].spaceID == "spA" && list[0].tabID == "tb1")
    }
}

@Suite struct GroupingAndNoticeTests {
    @Test func onlyDoneIsDismissedOnOpen() {
        #expect(AgentState.done.isDismissedOnOpen)
        #expect(!AgentState.working.isDismissedOnOpen)
        #expect(!AgentState.needsYou.isDismissedOnOpen)
        #expect(!AgentState.idle.isDismissedOnOpen)
    }

    @Test func spacesAndAgentsAreOrderedByUrgency() {
        let groups = Grouping.bySpace(agents())
        #expect(groups.map(\.name) == ["Blog", "Shop", "notes"])               // needs you, done, idle
        #expect(groups[1].agents.map(\.name) == ["coder1", "coder2", "lead"])  // done, working, idle
        #expect(groups[1].counts.done == 1 && groups[1].counts.working == 1 && groups[1].counts.idle == 1)
    }

    @Test func menuSectionsGoQuestionsWorkingDoneIdle() {
        var list = agents()
        list.append(Agent(address: "t9", name: "debugger", space: "Blog", tab: "agents", app: "claude-code",
                          status: "working", statusChanged: Date(timeIntervalSince1970: 1_796_000_000)))
        let sections = Grouping.byState(list)
        #expect(sections.map(\.state) == [.needsYou, .working, .done, .idle])
        #expect(sections[1].agents.map(\.name) == ["debugger", "coder2"])   // the more recent change first
        #expect(sections[3].agents.map(\.name) == ["lead", "designer"])
        #expect(Grouping.byState(list.filter { $0.state != .done }).map(\.state) == [.needsYou, .working, .idle])
    }

    @Test func noticesOnlyForChangesIntoNeedsYouOrDone() {
        let before = agents()
        var after = before
        after[2].status = "blocked"; after[2].kind = "question"     // working -> needs you
        after[0].turn = 13                                          // idle (seen) -> done (unseen)
        after[3].status = "working"                                 // needs you -> working: no notice
        let notices = Notices.between(old: before, new: after, muted: [])
        #expect(notices.map(\.agent.name).sorted() == ["coder2", "lead"])
        #expect(notices.first { $0.agent.name == "coder2" }?.body == "Has a question")
        #expect(Notice(agent: after[2], excerpt: "Which branch?").body == "Has a question — Which branch?")
        #expect(notices.first { $0.agent.name == "lead" }?.title == "Shop · lead")
    }

    @Test func noNoticeOnFirstSightOrWhenMuted() {
        #expect(Notices.between(old: [], new: agents(), muted: []).isEmpty)
        var after = agents()
        after[2].status = "blocked"
        #expect(Notices.between(old: agents(), new: after, muted: ["Shop/coder2"]).isEmpty)
    }
}
