import AppKit
import HerdbarCore
import SwiftUI

/// The content of the menu that drops from the menu bar item.
struct MenuView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: 380)
        .fontDesign(.rounded)
        // A mostly solid backing over the panel's blur, so whatever is behind the menu does
        // not wash out the text.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.82))
        .overlay {
            RoundedRectangle(cornerRadius: MenuPanelController.cornerRadius)
                .strokeBorder(Color.primary.opacity(0.1))
        }
        .focusEffectDisabled()
    }

    /// The counts are in the menu bar, right above; the header only names the app and holds
    /// its two buttons.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Herdbar").font(.title3.weight(.semibold))
            Spacer()
            HeaderButton(symbol: "gearshape.fill", help: "Settings (⌘,)") {
                model.openSettings(model.settingsPane)
            }
            HeaderButton(symbol: "power", help: "Quit Herdbar (⌘Q)") {
                model.requestQuit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if case .failed(let reason) = model.connection, model.agents.isEmpty {
            message(reason, symbol: "bolt.horizontal.circle")
        } else if model.agents.isEmpty {
            message(model.connection == .connecting ? "Connecting to Herdr…" : "No agents are running in Herdr.",
                    symbol: "moon.zzz")
        } else if model.sections.isEmpty {
            message("All \(model.agents.count) agents are idle.", symbol: "moon.zzz")
        } else {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if case .failed(let reason) = model.connection {
                        Label(reason + " Showing the last reading.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                    }
                    ForEach(model.sections) { section in
                        StateSection(section: section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            // Keep the row the keyboard is on in view.
            .onChange(of: model.selectedRow) { _, row in
                if let row {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(row) }
                }
            }
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }
}

/// The agents in one state, as a card: questions, working, done or idle. The Idle card
/// starts closed, showing only how many there are.
private struct StateSection: View {
    @Environment(AppModel.self) private var model
    let section: StateGroup
    @State private var isHovered = false

    var body: some View {
        let isIdle = section.state == .idle
        let isOpen = !isIdle || model.showsIdle
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard isIdle else { return }
                withAnimation(.easeOut(duration: 0.15)) { model.showsIdle.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.state.symbol).stateStyle(section.state, size: 14)
                        .frame(width: 18)
                    Text(section.state.label).font(.headline)
                    Text("\(section.agents.count)")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    let hidden = model.hiddenMuted(in: section.state)
                    if hidden > 0 {
                        Label("\(hidden) muted", systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .help("\(hidden) muted agent\(hidden == 1 ? " is" : "s are") not listed here. Change this in Settings → Agents.")
                    }
                    Spacer()
                    if section.state == .done {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { model.dismissAllDone() }
                        } label: {
                            // Two ticks, the second overlapping the first: "all of them".
                            HStack(spacing: -6) {
                                Image(systemName: "checkmark")
                                Image(systemName: "checkmark")
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 16, alignment: .trailing)
                            .contentShape(Rectangle().inset(by: -4))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss all Done agents (⇧.)")
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(isHovered)
                        .accessibilityLabel("Dismiss all Done agents")
                    }
                    if isIdle {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(RowHighlight(isHovered: false, isSelected: isIdle && model.selectedRow == AppModel.idleRow))
                .id(isIdle ? AppModel.idleRow : "#\(section.state.rawValue)")
            }
            .buttonStyle(.plain)

            if isOpen {
                ForEach(section.agents) { agent in
                    AgentRow(agent: agent)
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)) }
        .onHover { isHovered = $0 }
    }
}

/// One agent: its space and name, what it is doing, and how long for. A click opens Herdr;
/// the bell mutes its notifications.
private struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var isHovered = false

    /// The height of the row's small buttons: no more than one line of its text, so the row
    /// does not grow, and nothing moves, when they appear under the pointer.
    private static let iconHeight: CGFloat = 16

    var body: some View {
        let muted = model.isMuted(agent)
        let isExpanded = model.expandedRow == agent.address
        let words = isExpanded ? model.lastWords[agent.address] : nil
        VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .top, spacing: 10) {
            Color.clear.frame(width: 18, height: 1)
            VStack(alignment: .leading, spacing: 1) {
                // Agents that can notify you are in bold; muted ones are grey and plain.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(agent.space)
                        .font(.body.weight(muted ? .regular : .semibold))
                        .foregroundStyle(muted ? Color.secondary : Color.primary)
                    Text("· " + agent.name)
                        .font(.body)
                        .foregroundStyle(muted ? Color.secondary.opacity(0.8) : Color.primary.opacity(0.8))
                }
                .lineLimit(1)
                // The card already says the state; show the line only when it adds something.
                if agent.detail != agent.state.label, agent.detail != "Finished" {
                    // Plain text, not the state's colour: coloured text is hard to read on
                    // the translucent panel. The card's icon already carries the colour.
                    // One line normally; all of it when the row is opened out.
                    Text(agent.detail)
                        .font(.callout)
                        .foregroundStyle(muted ? Color.secondary.opacity(0.8) : Color.primary.opacity(0.75))
                        .lineLimit(isExpanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: isExpanded)
                }
            }
            Spacer(minLength: 6)
            // Dismiss: on hover only, and only for an agent that is not idle.
            if isHovered, agent.state != .idle {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.dismissAgent(agent) }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20, height: Self.iconHeight)
                        .contentShape(Rectangle().inset(by: -3))
                }
                .buttonStyle(.plain)
                .help("Dismiss: move to Idle until it changes (. or Delete)")
            }
            if isHovered || isExpanded {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(agent) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: Self.iconHeight)
                        .contentShape(Rectangle().inset(by: -3))
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Show less (←)" : "Show everything it said (→)")
            }
            if isHovered || muted {
                Button {
                    model.toggleMute(agent)
                } label: {
                    Image(systemName: muted ? "bell.slash.fill" : "bell")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 22, height: Self.iconHeight)
                        .contentShape(Rectangle().inset(by: -3))
                }
                .buttonStyle(.plain)
                .help(muted ? "Muted: no notifications from this agent. Click to unmute." : "Mute this agent's notifications")
            }
            Text(Age.short(since: agent.statusChanged))
                .font(.callout.monospacedDigit())
                .foregroundStyle(muted ? Color.secondary.opacity(0.8) : Color.primary.opacity(0.7))
                .frame(minWidth: 26, minHeight: Self.iconHeight, alignment: .trailing)
        }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = words?.title {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(agent.state.colour)
                            Text(title).font(.callout.weight(.semibold))
                        }
                        .padding(.top, 4)
                    }
                    if let message = words?.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    } else if agent.sessionID == nil {
                        Text("Nothing more to show for this agent.").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(RowHighlight(isHovered: isHovered, isSelected: model.selectedRow == agent.address))
        .id(agent.address)
        .onHover { isHovered = $0 }
        .onTapGesture { model.openHerdr(agent) }
        .help("Open in Herdr")
    }
}
