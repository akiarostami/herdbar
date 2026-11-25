import AppKit
import HerdbarCore
import Observation
import SwiftUI

/// Herdbar's own notifications: cards that drop under the menu bar item and leave after the
/// time set in Settings. The panel never takes the keyboard or the focus.
@MainActor
final class BannerPanelController {
    private let panel: NSPanel
    private let host: NSHostingController<AnyView>
    private let model: AppModel
    private weak var anchor: NSStatusBarButton?
    private var size = CGSize.zero

    init(model: AppModel, anchor: NSStatusBarButton?) {
        self.model = model
        self.anchor = anchor
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let relay = Relay()
        host = NSHostingController(rootView: AnyView(
            BannerStack()
                .environment(model)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { relay.onChange?($0) }
        ))
        host.sizingOptions = []
        panel.contentView = host.view
        relay.onChange = { [weak self] size in
            // While the last banner is leaving, keep the panel's size so it is not clipped mid-way.
            guard let self, size.width > 1, size.height > 1, !self.model.banners.isEmpty else { return }
            self.size = size
            self.layout()
        }
        self.relay = relay
        track()
    }

    private var relay: Relay?
    private var hide: DispatchWorkItem?

    @MainActor
    private final class Relay {
        var onChange: ((CGSize) -> Void)?
    }

    /// Shows or hides the panel as banners come and go, and moves it when the place changes.
    private func track() {
        let hasBanners = withObservationTracking {
            _ = model.bannerPlace
            return !model.banners.isEmpty
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        if hasBanners {
            hide?.cancel()
            size = host.sizeThatFits(in: CGSize(width: 2000, height: 4000))
            layout()
            panel.orderFrontRegardless()
        } else {
            // Let the last banner finish leaving before the panel goes.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.banners.isEmpty else { return }
                self.panel.orderOut(nil)
            }
            hide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Puts the panel at the chosen place, on the screen that has Herdbar's menu bar icon.
    /// Top places hang from the top edge and grow downwards; bottom places sit on the bottom
    /// edge and grow upwards.
    private func layout() {
        guard size.width > 1, size.height > 1, let button = anchor, let window = button.window,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let margin: CGFloat = 12
        let width = size.width.rounded(.up)
        let height = size.height.rounded(.up)
        let place = model.bannerPlace

        let x: CGFloat
        switch place {
        case .underIcon: x = min(max(icon.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        case .topLeft, .bottomLeft: x = visible.minX + margin
        case .topCentre, .bottomCentre: x = visible.midX - width / 2
        case .topRight, .bottomRight: x = visible.maxX - width - margin
        }
        let y: CGFloat
        switch place {
        case .underIcon: y = icon.minY - 6 - height
        case .topLeft, .topCentre, .topRight: y = visible.maxY - margin - height
        case .bottomLeft, .bottomCentre, .bottomRight: y = visible.minY + margin
        }
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), display: true)
    }
}

/// The banners on screen, newest at the bottom.
private struct BannerStack: View {
    @Environment(AppModel.self) private var model

    private var fromBottom: Bool { model.bannerPlace.isBottom }
    private var edge: Edge { fromBottom ? .bottom : .top }
    private var anchor: UnitPoint { fromBottom ? .bottom : .top }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.banners) { notice in
                BannerCard(notice: notice)
                    // Comes in from the screen edge it sits against, with a little spring;
                    // fades and slips back towards that edge.
                    .transition(.asymmetric(
                        insertion: .move(edge: edge).combined(with: .opacity).combined(with: .scale(scale: 0.94, anchor: anchor)),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: anchor)).combined(with: .offset(y: fromBottom ? 8 : -8))))
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, fromBottom ? 14 : 2)
        .padding(.bottom, fromBottom ? 2 : 14)
        .frame(width: 376, alignment: fromBottom ? .bottom : .top)
        .fontDesign(.rounded)
    }
}

struct BannerCard: View {
    @Environment(AppModel.self) private var model
    let notice: Notice
    @State private var isHovered = false

    var body: some View {
        let state = notice.agent.state
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol).stateStyle(state, size: 18)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notice.title).font(.headline).foregroundStyle(.white)
                    Text(notice.event)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.colour)
                }
                if let headline = notice.headline {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(state.colour)
                        Text(headline)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                if let excerpt = notice.excerpt {
                    Text(excerpt)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.dismiss(notice)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(14)
        .frame(width: 372, alignment: .leading)
        .background {
            ZStack {
                Color(white: 0.08)
                state.colour.opacity(0.16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(state.colour.opacity(isHovered ? 0.9 : 0.55)) }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            isHovered = hovering
            model.hold(notice, hovering)
        }
        .onTapGesture {
            model.openHerdr(notice.agent)
            model.dismiss(notice)
        }
        .help("Open in Herdr")
    }
}
