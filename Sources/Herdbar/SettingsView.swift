import HerdbarCore
import SwiftUI

/// The settings window: a fixed sidebar and one page per topic.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding<SettingsPane?>(
                get: { model.settingsPane },
                set: { model.settingsPane = $0 ?? .general }
            )) {
                SidebarItem(title: "General", symbol: "gearshape").tag(SettingsPane.general)
                SidebarItem(title: "Notifications", symbol: "bell").tag(SettingsPane.notifications)
                SidebarItem(title: "Agents", symbol: "sparkles").tag(SettingsPane.agents)
                Section {
                    SidebarItem(title: "About", symbol: "info.circle").tag(SettingsPane.about)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)

            Divider().ignoresSafeArea()

            Group {
                switch model.settingsPane {
                case .general: GeneralPage()
                case .notifications: NotificationsPage()
                case .agents: AgentsPage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 560)
    }
}

/// A sidebar row whose icon has a fixed width, so wide and narrow symbols line up and none
/// crowds its title.
private struct SidebarItem: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title).padding(.leading, 2)
        } icon: {
            Image(systemName: symbol).frame(width: 22)
        }
    }
}

/// A note under a section, left-aligned.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GeneralPage: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if enabled != model.launchAtLogin { model.setLaunchAtLogin(enabled) }
                    }
            }

            Section {
                LabeledContent("Open Herdbar") {
                    ShortcutRecorder(combo: $model.hotKey)
                }
                if model.hotKeyRefused {
                    Label("macOS refused this shortcut; another app may be using it. Try a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Open the last notification") {
                    ShortcutRecorder(combo: $model.lastNoticeHotKey)
                }
                if model.lastNoticeHotKeyRefused {
                    Label("macOS refused this shortcut; another app may be using it. Try a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Footnote("The second acts like a click on the most recent notification, even after its banner has gone.")
            }

            Section {
                Toggle("List idle agents in the menu", isOn: $model.listsIdle)
                Toggle("Show the idle count in the menu bar", isOn: $model.countsIdleInMenuBar)
            } header: {
                Text("Idle agents")
            }

            Section {
                Toggle("Dismiss an agent when I open it in Herdr", isOn: $model.dismissesOnOpen)
                Picker("Dismiss Done agents after", selection: $model.autoDismissDoneMinutes) {
                    Text("Never").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
            } header: {
                Text("Dismissing")
            } footer: {
                Footnote("A dismissed agent returns when its state next changes. ⌘Z in the menu undoes the last dismissal.")
            }

            Section {
                Toggle("Switch Herdr to the agent's space and tab", isOn: $model.jumpsToSpace)
                if model.jumpsToSpace {
                    LabeledContent("Accessibility permission") {
                        if model.hasAccessibilityPermission {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Open System Settings…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Opening an agent")
            } footer: {
                Footnote("Herdbar presses Herdr's own shortcuts: Control-1 to 9 for the space, Command-1 to 9 for the tab. It reaches the first nine of each.")
            }

            Section {
                LabeledContent("Herdr") {
                    switch model.connection {
                    case .live: Label("Connected, \(model.agents.count) agents", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .connecting: Text("Connecting…").foregroundStyle(.secondary)
                    case .failed(let reason): Text(reason).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Footnote("Herdbar only reads from Herdr.")
            }

            Section {
                HStack {
                    Text("Herdbar has no Dock icon; quit it here or from its menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit Herdbar") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLogin }
    }
}

private struct NotificationsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Show", selection: $model.notifyStyle) {
                    ForEach(NotifyStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("How")
            }

            Section {
                LabeledContent {
                    PlacePicker(place: $model.bannerPlace)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Where")
                        Text(model.bannerPlace.title).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.notifyStyle != .banner)
                Stepper(value: $model.bannerSeconds, in: 2...120, step: 1) {
                    LabeledContent("Keep a banner for", value: "\(model.bannerSeconds) seconds")
                }
                .disabled(model.notifyStyle != .banner)
                Button("Show a Test Banner") {
                    if let agent = model.agents.first(where: { $0.state == .needsYou || $0.state == .done }) ?? model.agents.first {
                        model.showTestBanner(for: agent)
                    }
                }
                .disabled(model.notifyStyle != .banner || model.agents.isEmpty)
            } header: {
                Text("Herdbar banners")
            } footer: {
                Footnote("The duration applies to Herdbar banners; macOS decides how long its own notifications stay.")
            }

            Section {
                Toggle("Notify me", isOn: $model.notifyNeedsYou)
                Toggle("Play a sound", isOn: $model.soundNeedsYou)
                    .disabled(!model.notifyNeedsYou)
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
                    Text("When an agent needs you")
                }
            }

            Section {
                Toggle("Notify me", isOn: $model.notifyDone)
                Toggle("Play a sound", isOn: $model.soundDone)
                    .disabled(!model.notifyDone)
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("When an agent finishes")
                }
            } footer: {
                Footnote("macOS notifications use the system sound for both.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A small picture of the screen with a spot for each place a banner can appear. Click a
/// spot to choose it.
private struct PlacePicker: View {
    @Binding var place: BannerPlace
    private let size = CGSize(width: 190, height: 112)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.06))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.2)) }
            // The menu bar, with Herdbar's icon towards the right.
            Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 9)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9))
            Circle().fill(Color.primary.opacity(0.55)).frame(width: 5, height: 5)
                .offset(x: size.width * 0.72 - 2.5, y: 2)
            ForEach(BannerPlace.allCases) { option in
                spot(option)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func spot(_ option: BannerPlace) -> some View {
        let spotSize = CGSize(width: 44, height: 15)
        let inset: CGFloat = 8
        let x: CGFloat
        switch option {
        case .underIcon: x = size.width * 0.72 - spotSize.width / 2
        case .topLeft, .bottomLeft: x = inset
        case .topCentre, .bottomCentre: x = (size.width - spotSize.width) / 2
        case .topRight, .bottomRight: x = size.width - spotSize.width - inset
        }
        let y: CGFloat
        switch option {
        case .underIcon: y = 13
        case .topLeft, .topCentre, .topRight: y = 36
        case .bottomLeft, .bottomCentre, .bottomRight: y = size.height - spotSize.height - inset
        }
        let isOn = place == option
        return Button {
            place = option
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? Color.accentColor : Color.primary.opacity(0.16))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(isOn ? 0 : 0.18)) }
                .frame(width: spotSize.width, height: spotSize.height)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .offset(x: x, y: y)
        .help(option.title)
        .accessibilityLabel(option.title)
    }
}

/// Every agent, by space, with its notification setting: Default, Notify or Muted.
private struct AgentsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Agents set to Default", selection: $model.defaultRule) {
                    ForEach(AgentRule.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Default")
            } footer: {
                Footnote("A muted agent sends no notifications. It is still listed in the menu, in grey, and counted in the menu bar.")
            }

            Section {
                ForEach(Grouping.menuOrder, id: \.self) { state in
                    Toggle(isOn: model.hidesMutedBinding(state)) {
                        HStack(spacing: 8) {
                            Image(systemName: state.symbol).foregroundStyle(state.colour).frame(width: 18)
                            Text("Show under \(state.label)")
                        }
                    }
                }
            } header: {
                Text("Muted agents in the menu")
            } footer: {
                Footnote("Switch one off to keep muted agents out of that part of the menu and out of its count in the menu bar.")
            }

            if model.agents.isEmpty {
                Section {
                    Text("No agents are running in Herdr.").foregroundStyle(.secondary)
                }
            }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.agents) { agent in
                        RuleRow(key: agent.muteKey) {
                            HStack(spacing: 8) {
                                Image(systemName: agent.state.symbol).foregroundStyle(agent.state.colour).frame(width: 18)
                                Text(agent.name)
                                if !agent.tab.isEmpty, agent.tab != agent.name {
                                    Text(agent.tab).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        Menu("Set All") {
                            Button("Default") { group.agents.forEach { model.setRule(nil, for: $0.muteKey) } }
                            ForEach(AgentRule.allCases) { rule in
                                Button(rule.title) { group.agents.forEach { model.setRule(rule, for: $0.muteKey) } }
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
            }
            let live = Set(model.agents.map(\.muteKey))
            let stale = model.rules.keys.filter { !live.contains($0) }.sorted()
            if !stale.isEmpty {
                Section {
                    ForEach(stale, id: \.self) { key in
                        RuleRow(key: key) {
                            Text(key.replacingOccurrences(of: "/", with: " · ")).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("With a setting, not running now")
                } footer: {
                    Footnote("Set one to Default to forget it.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One agent's setting, as three buttons in a bar: Default, Notify, Muted.
private struct RuleRow<Label: View>: View {
    @Environment(AppModel.self) private var model
    let key: String
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack {
            label()
            Spacer()
            Picker("", selection: Binding<AgentRule?>(
                get: { model.rules[key] },
                set: { model.setRule($0, for: key) }
            )) {
                Text("Default").tag(AgentRule?.none)
                ForEach(AgentRule.allCases) { Text($0.title).tag(AgentRule?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
        }
    }
}

private struct AboutPage: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 68, height: 68)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Herdbar").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Your Herdr agents in the menu bar: who is working, who needs you, and who has finished.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Footnote("A personal tool. Not affiliated with Herdr.")
            }

            Section("Keyboard, with the menu open") {
                LabeledContent("Move between agents", value: "↑ ↓")
                LabeledContent("Open Herdr", value: "Return or Space")
                LabeledContent("Show everything an agent said, or less", value: "→ ←")
                LabeledContent("Open or close Idle", value: "→ ← or Return, on its heading")
                LabeledContent("Dismiss the agent to Idle", value: ". or Delete")
                LabeledContent("Dismiss every Done agent", value: "⇧.")
                LabeledContent("Undo the last dismissal", value: "⌘Z")
                LabeledContent("Mute or unmute the agent", value: "M")
                LabeledContent("Settings", value: "⌘,")
                LabeledContent("Close the menu", value: "Esc")
            }
        }
        .formStyle(.grouped)
    }
}
