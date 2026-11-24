import AppKit
import HerdbarCore
import Observation
import ServiceManagement
import SwiftUI

/// How the user is told that an agent needs them or has finished.
enum NotifyStyle: String, CaseIterable, Identifiable {
    case off, system, banner
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .system: return "macOS notifications"
        case .banner: return "Herdbar banners"
        }
    }
}

/// Where Herdbar's banners appear on the screen.
enum BannerPlace: String, CaseIterable, Identifiable {
    case underIcon, topLeft, topCentre, topRight, bottomLeft, bottomCentre, bottomRight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .underIcon: return "Under the menu bar icon"
        case .topLeft: return "Top left"
        case .topCentre: return "Top centre"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomCentre: return "Bottom centre"
        case .bottomRight: return "Bottom right"
        }
    }

    var isBottom: Bool { [.bottomLeft, .bottomCentre, .bottomRight].contains(self) }
}

/// An agent's own notification setting. An agent without one follows the app's default.
enum AgentRule: String, CaseIterable, Identifiable {
    case notify, muted
    var id: String { rawValue }

    var title: String {
        switch self {
        case .notify: return "Notify"
        case .muted: return "Muted"
        }
    }
}

enum SettingsPane: Hashable {
    case general, notifications, agents, about
}

/// The app's state: the agents Herdr reports, what is muted, and how to notify.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case connecting
        case live
        case failed(String)
    }

    var agents: [Agent] = []
    var connection = Connection.connecting
    /// Banners currently on screen, oldest first.
    var banners: [Notice] = []
    var settingsPane = SettingsPane.general
    var hotKeyRefused = false
    /// Whether the menu's Idle section is open.
    var showsIdle = false
    /// The row the keyboard is on: an agent's address, or `idleRow`; nil until an arrow key is pressed.
    var selectedRow: String?
    static let idleRow = "#idle"
    /// Agents you have dismissed, by address, with the state and turn they were in. A
    /// dismissed agent is shown as idle until it changes.
    var dismissed: [String: String] = [:]
    /// Each dismissal you made, as the addresses it covered, oldest first.
    @ObservationIgnored private var undoStack: [[String]] = []
    /// The agent whose row is opened out to show everything it has said, by address.
    var expandedRow: String?
    /// What each opened agent last said, read from its transcript when its row is opened.
    var lastWords: [String: Transcript.Latest] = [:]

    /// Agents with a setting of their own, by space and name. The rest follow `defaultRule`.
    var rules: [String: AgentRule] {
        didSet { save(rules.mapValues(\.rawValue), "agentRules") }
    }
    /// What agents without their own setting do: notify, or stay muted.
    var defaultRule: AgentRule {
        didSet { save(defaultRule.rawValue, "defaultRule") }
    }
    var notifyStyle: NotifyStyle {
        didSet { save(notifyStyle.rawValue, "notifyStyle") }
    }
    /// How long a Herdbar banner stays before it goes away, in seconds.
    var bannerSeconds: Int {
        didSet { save(bannerSeconds, "bannerSeconds") }
    }
    var bannerPlace: BannerPlace {
        didSet { save(bannerPlace.rawValue, "bannerPlace") }
    }
    var notifyNeedsYou: Bool {
        didSet { save(notifyNeedsYou, "notifyNeedsYou") }
    }
    var notifyDone: Bool {
        didSet { save(notifyDone, "notifyDone") }
    }
    /// Whether each kind of notification plays a sound.
    var soundNeedsYou: Bool {
        didSet { save(soundNeedsYou, "soundNeedsYou") }
    }
    var soundDone: Bool {
        didSet { save(soundDone, "soundDone") }
    }
    /// Whether idle agents are listed in the menu, and counted in the menu bar.
    var listsIdle: Bool {
        didSet { save(listsIdle, "listsIdle") }
    }
    var countsIdleInMenuBar: Bool {
        didSet { save(countsIdleInMenuBar, "countsIdleInMenuBar") }
    }
    /// The menu's groups that leave muted agents out.
    var hidesMutedIn: Set<AgentState> {
        didSet { save(hidesMutedIn.map(\.rawValue).sorted(), "hidesMutedIn") }
    }
    /// Whether opening a Done agent in Herdr also dismisses it here.
    var dismissesOnOpen: Bool {
        didSet { save(dismissesOnOpen, "dismissesOnOpen") }
    }
    /// Minutes after which a Done agent is dismissed by itself; 0 for never.
    var autoDismissDoneMinutes: Int {
        didSet { save(autoDismissDoneMinutes, "autoDismissDoneMinutes") }
    }
    /// Whether opening an agent also switches Herdr to its space and tab.
    var jumpsToSpace: Bool {
        didSet { save(jumpsToSpace, "jumpsToSpace") }
    }
    var hotKey: KeyCombo? {
        didSet { save(hotKey.flatMap { try? JSONEncoder().encode($0) }, "hotKey") }
    }
    /// The system-wide shortcut that acts like a click on the last notification.
    var lastNoticeHotKey: KeyCombo? {
        didSet { save(lastNoticeHotKey.flatMap { try? JSONEncoder().encode($0) }, "lastNoticeHotKey") }
    }
    var lastNoticeHotKeyRefused = false
    /// The most recent notification shown, in whichever style.
    private(set) var lastNotice: Notice?

    /// Set by the app delegate.
    @ObservationIgnored var openSettings: (SettingsPane) -> Void = { _ in }
    @ObservationIgnored var requestQuit: () -> Void = {}
    @ObservationIgnored var deliverSystemNotification: (Notice) -> Void = { _ in }

    @ObservationIgnored private let feed = HerdrProcess()
    @ObservationIgnored private var hasSnapshot = false
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var resnapshot: DispatchWorkItem?
    @ObservationIgnored private var bannerTimers: [String: DispatchWorkItem] = [:]

    init() {
        // Demo mode starts from the app's defaults each time, not from the saved settings.
        let defaults: UserDefaults
        if DemoData.isOn, let demo = UserDefaults(suiteName: "com.minorkey.herdbar.demo") {
            demo.removePersistentDomain(forName: "com.minorkey.herdbar.demo")
            defaults = demo
        } else {
            defaults = .standard
        }
        defaults.register(defaults: ["notifyStyle": NotifyStyle.banner.rawValue, "bannerSeconds": 6,
                                     "notifyNeedsYou": true, "notifyDone": true,
                                     "soundNeedsYou": true, "soundDone": false, "listsIdle": true,
                                     "jumpsToSpace": true, "dismissesOnOpen": true])
        var stored = (defaults.dictionary(forKey: "agentRules") as? [String: String] ?? [:])
            .compactMapValues(AgentRule.init(rawValue:))
        // Carry over mutes saved by earlier builds, which kept a plain list. Done once: the old
        // list is then removed, so an agent later put back on Default is not muted again.
        if let old = defaults.stringArray(forKey: "muted"), !DemoData.isOn {
            for key in old where stored[key] == nil {
                stored[key] = .muted
            }
            defaults.set(stored.mapValues(\.rawValue), forKey: "agentRules")
            defaults.removeObject(forKey: "muted")
        }
        rules = stored
        defaultRule = AgentRule(rawValue: defaults.string(forKey: "defaultRule") ?? "") ?? .notify
        notifyStyle = NotifyStyle(rawValue: defaults.string(forKey: "notifyStyle") ?? "") ?? .banner
        bannerSeconds = max(2, defaults.integer(forKey: "bannerSeconds"))
        bannerPlace = BannerPlace(rawValue: defaults.string(forKey: "bannerPlace") ?? "") ?? .underIcon
        notifyNeedsYou = defaults.bool(forKey: "notifyNeedsYou")
        notifyDone = defaults.bool(forKey: "notifyDone")
        soundNeedsYou = defaults.bool(forKey: "soundNeedsYou")
        soundDone = defaults.bool(forKey: "soundDone")
        listsIdle = defaults.bool(forKey: "listsIdle")
        countsIdleInMenuBar = defaults.bool(forKey: "countsIdleInMenuBar")
        jumpsToSpace = defaults.bool(forKey: "jumpsToSpace")
        dismissesOnOpen = defaults.bool(forKey: "dismissesOnOpen")
        hidesMutedIn = Set((defaults.array(forKey: "hidesMutedIn") as? [Int] ?? []).compactMap(AgentState.init(rawValue:)))
        autoDismissDoneMinutes = defaults.integer(forKey: "autoDismissDoneMinutes")
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
        lastNoticeHotKey = defaults.data(forKey: "lastNoticeHotKey").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }

        if DemoData.isOn {
            rules = ["Storefront/reviewer": .muted, "Blog/lead": .muted, "Storefront/coder1": .notify]
            lastWords = ["t4": Transcript.Latest(
                title: "Review the payment tests",
                message: "I've read through the payment tests. Three of them assert on the provider's sandbox responses and will break when the sandbox changes; I'd replace those with recorded fixtures. The refund path has no test at all. I'm writing one now and will then look at the retry logic, which has a race between the webhook and the polling job.")]
            agents = DemoData.agents()
            connection = .live
            return
        }
        feed.onLine = { [weak self] line in self?.receive(line) }
        feed.onStop = { [weak self] reason in self?.feedStopped(reason) }
        feed.start()
        schedulePeriodicSnapshot()
    }

    private func save(_ value: Any?, _ key: String) {
        if !DemoData.isOn { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: What the menu shows

    /// The agent's own setting, or nil when it follows the default.
    func rule(for agent: Agent) -> AgentRule? { rules[agent.muteKey] }

    func isMuted(_ agent: Agent) -> Bool { (rules[agent.muteKey] ?? defaultRule) == .muted }

    /// Gives the agent its own setting, or with nil puts it back on the default.
    func setRule(_ rule: AgentRule?, for key: String) {
        if let rule {
            rules[key] = rule
        } else {
            rules.removeValue(forKey: key)
        }
    }

    /// The agents as the menu and the counts show them: dismissed ones as idle.
    var shown: [Agent] {
        agents.map { agent in
            guard dismissed[agent.address] == Self.signature(agent) else { return agent }
            var agent = agent
            agent.status = "idle"
            agent.kind = nil
            agent.message = nil
            return agent
        }
    }

    private static func signature(_ agent: Agent) -> String { "\(agent.state.rawValue):\(agent.turn)" }

    /// Whether the agent has something to dismiss: it is not idle, as shown.
    func canDismiss(_ agent: Agent) -> Bool {
        agent.state != .idle && dismissed[agent.address] != Self.signature(agent)
    }

    /// Clears an agent from Needs you, Working or Done in Herdbar. It moves to Idle and
    /// leaves the counts, and comes back by itself the next time its state changes.
    /// Nothing is sent to Herdr.
    func dismissAgent(_ agent: Agent) {
        guard canDismiss(agent) else { return }
        // Keep the keyboard on a sensible row: the one after, else the one before.
        let rows = navigableRows
        if selectedRow == agent.address, let index = rows.firstIndex(of: agent.address) {
            selectedRow = index + 1 < rows.count && rows[index + 1] != Self.idleRow ? rows[index + 1]
                : (index > 0 ? rows[index - 1] : nil)
        }
        dismiss([agent], undoable: true)
    }

    /// Dismisses every agent shown under Done, as one step that Undo brings back together.
    func dismissAllDone() {
        dismiss(agents.filter { $0.state == .done && canDismiss($0) }, undoable: true)
        if let row = selectedRow, !navigableRows.contains(row) { selectedRow = nil }
    }

    private func dismiss(_ list: [Agent], undoable: Bool) {
        let list = list.filter(canDismiss)
        guard !list.isEmpty else { return }
        for agent in list {
            if expandedRow == agent.address { expandedRow = nil }
            dismissed[agent.address] = Self.signature(agent)
            if let banner = banners.first(where: { $0.agent.address == agent.address }) { dismiss(banner) }
        }
        if undoable {
            undoStack.append(list.map(\.address))
            if undoStack.count > 30 { undoStack.removeFirst() }
        }
    }

    /// Brings back the agents of the last dismissal you made. Returns false when there is
    /// none left to undo.
    @discardableResult
    func undoDismiss() -> Bool {
        guard let last = undoStack.popLast() else { return false }
        for address in last { dismissed.removeValue(forKey: address) }
        selectedRow = last.first { navigableRows.contains($0) } ?? selectedRow
        return true
    }

    /// Dismisses Done agents that finished longer ago than the time set in Settings.
    /// Not part of Undo, which is for what you dismissed yourself.
    func autoDismissDone(now: Date = Date()) {
        guard autoDismissDoneMinutes > 0 else { return }
        let limit = TimeInterval(autoDismissDoneMinutes * 60)
        dismiss(agents.filter { agent in
            agent.state == .done && (agent.statusChanged.map { now.timeIntervalSince($0) > limit } ?? false)
        }, undoable: false)
    }

    /// The counts in the menu bar: what the menu lists. A muted agent counts like any other
    /// unless muted agents are kept out of its part of the menu. Dismissed agents count as idle.
    var counts: Counts { Counts(shown.filter { !(hidesMutedIn.contains($0.state) && isMuted($0)) }) }

    /// By space, for Settings.
    var groups: [SpaceGroup] { Grouping.bySpace(shown) }

    /// By state, for the menu: questions, working, done, and idle when that is switched on.
    /// Muted agents are left out of the groups where that is switched on; a group with
    /// nothing left to list is left out too.
    var sections: [StateGroup] {
        Grouping.byState(shown).compactMap { group in
            guard listsIdle || group.state != .idle else { return nil }
            guard hidesMutedIn.contains(group.state) else { return group }
            let listed = group.agents.filter { !isMuted($0) }
            return listed.isEmpty ? nil : StateGroup(state: group.state, agents: listed)
        }
    }

    /// How many muted agents are in a state but not listed under it.
    func hiddenMuted(in state: AgentState) -> Int {
        guard hidesMutedIn.contains(state) else { return 0 }
        return shown.filter { $0.state == state && isMuted($0) }.count
    }

    func hidesMutedBinding(_ state: AgentState) -> Binding<Bool> {
        Binding(get: { !self.hidesMutedIn.contains(state) },
                set: { lists in
                    if lists {
                        self.hidesMutedIn.remove(state)
                    } else {
                        self.hidesMutedIn.insert(state)
                    }
                })
    }

    /// Whether a notice of this kind plays a sound.
    func playsSound(for notice: Notice) -> Bool {
        notice.agent.state == .needsYou ? soundNeedsYou : soundDone
    }

    func toggleMute(_ agent: Agent) {
        // From the menu: flip what the agent does now, as a setting of its own.
        rules[agent.muteKey] = isMuted(agent) ? .notify : .muted
    }

    // MARK: Keyboard

    enum NavigationKey {
        case up, down, left, right, activate, mute, dismiss, dismissAllDone, undo
    }

    /// The rows the arrow keys move through, top to bottom: every agent on show, and the
    /// Idle group's heading, which opens and closes it.
    var navigableRows: [String] {
        sections.flatMap { section -> [String] in
            if section.state == .idle {
                return [Self.idleRow] + (showsIdle ? section.agents.map(\.address) : [])
            }
            return section.agents.map(\.address)
        }
    }

    /// Up and Down move the selection. Return or Space opens Herdr for an agent, or opens and
    /// closes Idle. Right and Left open and close Idle. M mutes or unmutes the agent.
    func navigate(_ key: NavigationKey) {
        let rows = navigableRows
        // Undo works even when everything has been dismissed and no rows are left.
        if key == .undo {
            if !undoDismiss() { NSSound.beep() }
            return
        }
        guard !rows.isEmpty else { return }
        let index = selectedRow.flatMap { rows.firstIndex(of: $0) }
        switch key {
        case .down:
            expandedRow = nil  // moving on closes the row that was opened out
            selectedRow = rows[index.map { min($0 + 1, rows.count - 1) } ?? 0]
        case .up:
            expandedRow = nil
            selectedRow = rows[index.map { max($0 - 1, 0) } ?? rows.count - 1]
        case .right:
            if selectedRow == Self.idleRow {
                showsIdle = true
            } else if let agent = agents.first(where: { $0.address == selectedRow }) {
                expand(agent)
            }
        case .left:
            if selectedRow == Self.idleRow {
                showsIdle = false
            } else if expandedRow != nil, expandedRow == selectedRow {
                expandedRow = nil
            } else if let row = selectedRow, sections.last?.state == .idle,
                      sections.last?.agents.contains(where: { $0.address == row }) == true {
                // From inside Idle, Left closes the group and lands on its heading.
                showsIdle = false
                selectedRow = Self.idleRow
            }
        case .activate:
            guard let row = selectedRow, index != nil else { return }
            if row == Self.idleRow {
                showsIdle.toggle()
            } else {
                openHerdr(agents.first { $0.address == row })
            }
        case .mute:
            if let agent = agents.first(where: { $0.address == selectedRow }) {
                toggleMute(agent)
            }
        case .dismiss:
            if let agent = agents.first(where: { $0.address == selectedRow }) {
                dismissAgent(agent)
            }
        case .dismissAllDone:
            dismissAllDone()
        case .undo:
            if !undoDismiss() { NSSound.beep() }
        }
    }

    /// Opens an agent's row out to its full description, and reads the whole of its last
    /// message from its transcript, off the main thread.
    func expand(_ agent: Agent) {
        expandedRow = agent.address
        guard let session = agent.sessionID, !DemoData.isOn else { return }
        let address = agent.address
        Task { [weak self] in
            let latest = await Task.detached(priority: .userInitiated) {
                Transcript.file(sessionID: session).map { Transcript.latest(in: $0, messageLimit: 6000) }
            }.value
            if let latest { self?.lastWords[address] = latest }
        }
    }

    func toggleExpanded(_ agent: Agent) {
        if expandedRow == agent.address {
            expandedRow = nil
        } else {
            expand(agent)
        }
    }

    // MARK: Herdr

    private func receive(_ text: String) {
        guard let line = HerdrFeed.parse(text) else { return }
        switch line {
        case .heartbeat:
            return
        case .snapshot(let list):
            update(to: list, announce: hasSnapshot)
            hasSnapshot = true
            connection = .live
        case .status(let address, let status, _, _):
            let stateChanged = agents.first { $0.address == address }?.status != status
            update(to: HerdrFeed.apply(line, to: agents), announce: true)
            // A change of state can come with a new turn or seen mark, which only a fresh
            // reading shows. A change of message alone does not need one.
            if stateChanged { scheduleSnapshot(after: 0.8) }
        case .other:
            scheduleSnapshot(after: 0.8)
        }
    }

    private func update(to list: [Agent], announce: Bool) {
        // A dismissal lasts only while the agent stays as it was.
        let current = Dictionary(list.map { ($0.address, Self.signature($0)) }, uniquingKeysWith: { a, _ in a })
        dismissed = dismissed.filter { current[$0.key] == $0.value }
        defer { autoDismissDone() }
        let silenced = Set(list.filter(isMuted).map(\.muteKey))
        let notices = announce ? Notices.between(old: agents, new: list, muted: silenced) : []
        agents = list
        for notice in notices where announced.insert(notice.id).inserted {
            if notice.agent.state == .needsYou, !notifyNeedsYou { continue }
            if notice.agent.state == .done, !notifyDone { continue }
            guard notifyStyle != .off else { continue }
            deliver(notice)
        }
    }

    /// Adds what the agent last said, read from its Claude transcript off the main thread,
    /// then shows the notice in the chosen style.
    private func deliver(_ notice: Notice) {
        Task { [weak self] in
            var notice = notice
            if let session = notice.agent.sessionID {
                let latest = await Task.detached(priority: .utility) {
                    Transcript.file(sessionID: session).map { Transcript.latest(in: $0) }
                }.value
                notice.headline = latest?.title
                notice.excerpt = latest?.message
            }
            guard let self else { return }
            switch self.notifyStyle {
            case .off: break
            case .system:
                self.lastNotice = notice
                self.deliverSystemNotification(notice)
            case .banner:
                self.show(notice, sound: self.playsSound(for: notice))
            }
        }
    }

    /// What a click on the last notification does: opens its agent in Herdr and, if its
    /// banner is still showing, dismisses it. Returns false when there has been none yet.
    @discardableResult
    func openLastNotice() -> Bool {
        guard let notice = lastNotice else { return false }
        // The agent as it is now, in case it has moved; else as it was when notified.
        openHerdr(agents.first { $0.address == notice.agent.address } ?? notice.agent)
        if let showing = banners.first(where: { $0.agent.address == notice.agent.address }) {
            dismiss(showing)
        }
        return true
    }

    /// A banner for an agent as it is now, with its last message; for the Test button.
    func showTestBanner(for agent: Agent) {
        let style = notifyStyle
        notifyStyle = .banner
        deliver(Notice(agent: agent))
        notifyStyle = style
    }

    /// Asks Herdr for a fresh reading by starting its event stream again; the stream always
    /// opens with a full snapshot.
    private func scheduleSnapshot(after delay: TimeInterval) {
        resnapshot?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.feed.start() }
        resnapshot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A fresh reading every half minute, for changes Herdr does not announce.
    private func schedulePeriodicSnapshot() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if self.connection == .live { self.feed.start() }
            self.autoDismissDone()
            self.schedulePeriodicSnapshot()
        }
    }

    private func feedStopped(_ reason: String) {
        connection = .failed(reason)
        // Try again shortly; Herdr may simply not be open yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.connection != .live else { return }
            self.feed.start()
        }
    }

    /// Brings Herdr to the front and, for an agent, switches Herdr to its space and tab.
    ///
    /// Herdr has no way to be told this from outside, so Herdbar presses Herdr's own shortcuts
    /// for it: Control-1 … 9 selects a space, Command-1 … 9 a tab. That needs the macOS
    /// Accessibility permission, and it assumes those shortcuts have not been changed in Herdr.
    func openHerdr(_ agent: Agent? = nil) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.herdr.app") else { return }
        // Opening a Done agent means you have dealt with it.
        if dismissesOnOpen, let agent, let current = agents.first(where: { $0.address == agent.address }),
           current.state.isDismissedOnOpen {
            dismiss([current], undoable: true)
        }
        let jump = jumpsToSpace ? agent.flatMap(position) : nil
        if jump != nil, !AXIsProcessTrusted() {
            // Ask once, by opening the system prompt; this click only brings Herdr forward.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            guard let jump, let pid = app?.processIdentifier, AXIsProcessTrusted() else { return }
            // Give Herdr a moment to become the active app, then the tab a moment after the space.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Self.press(digit: jump.space, flags: .maskControl, pid: pid)
                if let tab = jump.tab {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        Self.press(digit: tab, flags: .maskCommand, pid: pid)
                    }
                }
            }
        }
    }

    /// The agent's space and tab numbers in Herdr, when both are within reach of a shortcut.
    private func position(of agent: Agent) -> HerdrLayout.Position? {
        guard let spaceID = agent.spaceID, let data = try? Data(contentsOf: HerdrLayout.documentsFile),
              var position = HerdrLayout.position(spaceID: spaceID, tabID: agent.tabID, in: data),
              (1...9).contains(position.space) else { return nil }
        if let tab = position.tab, !(1...9).contains(tab) { position.tab = nil }
        return position
    }

    private static let digitKeys: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]

    /// Sends one key press, with modifiers, to one app.
    private static func press(digit: Int, flags: CGEventFlags, pid: pid_t) {
        guard let key = digitKeys[digit] else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    // MARK: Banners

    static let bannerAnimation = Animation.spring(response: 0.38, dampingFraction: 0.82)

    func show(_ notice: Notice, sound: Bool = false) {
        lastNotice = notice
        withAnimation(Self.bannerAnimation) {
            banners.removeAll { $0.agent.address == notice.agent.address }
            banners.append(notice)
        }
        if banners.count > 4 { dismiss(banners[0]) }
        startTimer(for: notice)
        if sound { Self.sound(for: notice.agent.state)?.play() }
    }

    func dismiss(_ notice: Notice) {
        bannerTimers[notice.id]?.cancel()
        bannerTimers[notice.id] = nil
        withAnimation(.easeIn(duration: 0.22)) {
            banners.removeAll { $0.id == notice.id }
        }
    }

    /// A different system sound for each kind, so you can tell them apart without looking.
    static func sound(for state: AgentState) -> NSSound? {
        NSSound(named: state == .needsYou ? "Funk" : "Glass")
    }

    /// Holds a banner while the pointer is over it, and starts its time again afterwards.
    func hold(_ notice: Notice, _ held: Bool) {
        if held {
            bannerTimers[notice.id]?.cancel()
        } else {
            startTimer(for: notice)
        }
    }

    private func startTimer(for notice: Notice) {
        bannerTimers[notice.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(notice) }
        bannerTimers[notice.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(bannerSeconds), execute: work)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
    }
}

/// Invented agents, shown when the app is launched with HERDBAR_DEMO set. Demo mode does not
/// talk to Herdr and saves nothing.
enum DemoData {
    static let isOn = ProcessInfo.processInfo.environment["HERDBAR_DEMO"] != nil

    static func agents(now: Date = Date()) -> [Agent] {
        func agent(_ address: String, _ space: String, _ tab: String, _ name: String, _ status: String,
                   minutes: Double, kind: String? = nil, message: String? = nil, unseen: Bool = false) -> Agent {
            Agent(address: address, name: name, space: space, tab: tab, app: "claude-code", status: status,
                  kind: kind, message: message, statusChanged: now.addingTimeInterval(-minutes * 60),
                  turn: 10, seenTurn: unseen ? 9 : 10)
        }
        return [
            agent("t1", "Storefront", "lead", "lead", "working", minutes: 0.4, message: "Planning the checkout rewrite"),
            agent("t2", "Storefront", "agents", "coder1", "blocked", minutes: 2, kind: "permission"),
            agent("t3", "Storefront", "agents", "coder2", "done", minutes: 1, unseen: true),
            agent("t4", "Storefront", "agents", "reviewer", "working", minutes: 6, message: "Reading the payment tests"),
            agent("t5", "Storefront", "agents", "designer", "done", minutes: 44),
            agent("t6", "Storefront", "architect", "architect", "idle", minutes: 190),
            agent("t7", "Blog", "lead", "lead", "done", minutes: 9, unseen: true),
            agent("t8", "Blog", "agents", "coder1", "blocked", minutes: 12, kind: "question"),
            agent("t9", "Blog", "agents", "debugger", "idle", minutes: 1500),
            agent("t10", "Internal Tools", "lead", "lead", "done", minutes: 2900),
            agent("t11", "Internal Tools", "agents", "coder1", "idle", minutes: 3100),
            agent("t12", "Internal Tools", "agents", "coder2", "idle", minutes: 3100),
        ]
    }
}
