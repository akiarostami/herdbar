import AppKit
import HerdbarCore
import SwiftUI

extension AgentState {
    var symbol: String {
        switch self {
        case .needsYou: return "ellipsis.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "play.fill"
        case .idle: return "circle"
        }
    }

    /// Whether the symbol has a white mark inside a coloured shape: the dots in the bubble,
    /// the tick in the disc.
    var hasWhiteMark: Bool { self == .needsYou || self == .done }

    /// How far to move the symbol down, as a share of its size, so it looks centred. The
    /// bubble's tail adds height below its body, so centring the whole box sits the body
    /// too high.
    var opticalDrop: CGFloat { self == .needsYou ? 0.09 : 0 }

    var colour: Color {
        switch self {
        case .needsYou: return .yellow
        case .done: return .green
        case .working: return .blue
        case .idle: return .secondary
        }
    }

    var nsColour: NSColor {
        switch self {
        case .needsYou: return .systemYellow
        case .done: return .systemGreen
        case .working: return .systemBlue
        case .idle: return .secondaryLabelColor
        }
    }
}

enum Age {
    /// "<1m", "9m", "3h", "2d": how long ago, as Herdr's own list writes it.
    static func short(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

/// The background of a row: tinted when the keyboard is on it, faint under the pointer.
struct RowHighlight: View {
    var isHovered: Bool
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(isHovered ? 0.07 : 0))
    }
}

/// A round icon button for the top of the menu. Its name is shown as a tooltip.
struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(isHovered ? 0.14 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A count with its state's icon, as in the menu bar.
struct CountChip: View {
    let state: AgentState
    let count: Int
    var showsLabel = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol).stateStyle(state, size: 11)
            Text(showsLabel ? "\(count) \(state.label.lowercased())" : "\(count)")
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
        }
    }
}

extension Image {
    /// The state's symbol at `size` points, in its colour, with a white mark inside where
    /// it has one, moved down where it needs to be to look centred.
    func stateStyle(_ state: AgentState, size: CGFloat) -> some View {
        self.symbolRenderingMode(.palette)
            .foregroundStyle(state.hasWhiteMark ? Color.white : state.colour, state.colour)
            .font(.system(size: size, weight: .heavy))
            .offset(y: size * state.opticalDrop)
    }
}
