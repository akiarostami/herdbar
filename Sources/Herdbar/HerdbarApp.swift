import AppKit
import HerdbarCore
import Observation
import SwiftUI
import UserNotifications

@main
struct HerdbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The menu bar item, menu, banners and settings window are managed by AppDelegate;
        // an App needs a scene, and this one shows nothing.
        Settings { EmptyView() }
    }
}

/// Owns the menu bar item, the menu that drops from it, the banner panel and the settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var menu: MenuPanelController!
    private var banners: BannerPanelController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A fixed name, matching the label's accessibility description, so menu bar managers
        // and macOS file the item under the same name.
        statusItem.autosaveName = "Herdbar"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggleMenu)
        }

        model.openSettings = { [weak self] pane in
            self?.model.settingsPane = pane
            self?.showSettings()
        }
        model.requestQuit = { [weak self] in self?.confirmQuit() }
        model.deliverSystemNotification = { [weak self] notice in self?.notify(notice) }
        menu = MenuPanelController(content: MenuView().environment(model))
        banners = BannerPanelController(model: model, anchor: statusItem.button)
        UNUserNotificationCenter.current().delegate = self

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(closeMenu), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        trackLabel()
        trackHotKey()
        trackMenuContent()
        trackNotifyStyle()
        runSelfCheckIfAsked()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
    }

    // MARK: Menu bar label

    private func trackLabel() {
        withObservationTracking {
            statusItem.button?.image = Self.label(model.counts, showsIdle: model.countsIdleInMenuBar)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackLabel() }
        }
    }

    /// The three counts as one picture: working, needs you, done. It is drawn each time it is
    /// shown, so the numbers take the menu bar's own text colour. A state's icon has its
    /// colour only while its count is above zero.
    static func label(_ counts: Counts, showsIdle: Bool = false) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        var parts: [(AgentState, Int)] = [(.working, counts.working), (.needsYou, counts.needsYou), (.done, counts.done)]
        if showsIdle { parts.append((.idle, counts.idle)) }
        // Icons share one height rather than one square, so the wide bubble is not shrunk;
        // heavy weight keeps them round and solid beside the system's own icons.
        let iconHeight: CGFloat = 16
        let gap: CGFloat = 3
        let spacing: CGFloat = 6
        let plain = NSImage.SymbolConfiguration(pointSize: 13, weight: .heavy)
        let icons: [(image: NSImage, size: NSSize)] = parts.map { part in
            // The bubble and the disc have two layers: a white mark, then the shape. At zero
            // the icon is drawn in one grey, like its number, with the mark cut out.
            let coloured = plain.applying(.init(paletteColors: part.0.hasWhiteMark
                ? [NSColor.white, part.0.nsColour] : [part.0.nsColour]))
            let image = NSImage(systemSymbolName: part.0.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(part.1 > 0 ? coloured : plain) ?? NSImage()
            // The bubble's tail adds height without weight, so it is drawn a little taller.
            let height = iconHeight * (part.0 == .needsYou ? 0.95 : 1)
            let width = image.size.height > 0 ? image.size.width * height / image.size.height : 0
            return (image, NSSize(width: width, height: height))
        }
        let widths = parts.map { ("\($0.1)" as NSString).size(withAttributes: [.font: font]).width }
        let total = widths.reduce(0, +) + icons.reduce(0) { $0 + $1.size.width } + CGFloat(parts.count) * gap
            + CGFloat(parts.count - 1) * spacing
        let image = NSImage(size: NSSize(width: ceil(total), height: 18), flipped: false) { rect in
            var x: CGFloat = 0
            for (index, part) in parts.enumerated() {
                let active = part.1 > 0
                let (symbol, size) = icons[index]
                let frame = NSRect(x: x, y: (rect.height - size.height) / 2 - (part.0 == .needsYou ? iconHeight * 0.04 : 0),
                                   width: size.width, height: size.height)
                if active {
                    symbol.draw(in: frame)
                } else {
                    // Tint with the grey made opaque, then draw at the grey's own opacity: a
                    // see-through tint over the black symbol would come out dark.
                    let grey = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .gray
                    NSImage(size: symbol.size, flipped: false) { bounds in
                        symbol.draw(in: bounds)
                        grey.withAlphaComponent(1).set()
                        bounds.fill(using: .sourceAtop)
                        return true
                    }.draw(in: frame, from: .zero, operation: .sourceOver, fraction: grey.alphaComponent)
                }
                x += size.width + gap
                let text = "\(part.1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: x, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
                x += widths[index] + spacing
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Herdbar"
        return image
    }

    // MARK: Shortcut and keys

    /// Registers both shortcuts now and again whenever either changes: one opens the menu,
    /// the other acts like a click on the last notification.
    private func trackHotKey() {
        let (menuCombo, noticeCombo) = withObservationTracking {
            (model.hotKey, model.lastNoticeHotKey)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackHotKey() }
        }
        model.hotKeyRefused = !HotKeyCenter.shared.set(slot: 1, combo: menuCombo) { [weak self] in
            self?.toggleMenu()
        }
        model.lastNoticeHotKeyRefused = !HotKeyCenter.shared.set(slot: 2, combo: noticeCombo) { [weak self] in
            guard let self else { return }
            self.closeMenu()
            if !self.model.openLastNotice() { NSSound.beep() }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard menu.isShown, event.window === menu.window else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.keyCode {
            case 43: model.openSettings(model.settingsPane)  // Command-comma
            case 6: model.navigate(.undo)                    // Command-Z
            case 12: NSApp.terminate(nil)                    // Command-Q
            default: return false
            }
            return true
        }
        if modifiers == .shift, event.keyCode == 47 {        // Shift-full stop
            model.navigate(.dismissAllDone)
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125: model.navigate(.down)
        case 126: model.navigate(.up)
        case 123: model.navigate(.left)
        case 124: model.navigate(.right)
        case 36, 76, 49:                      // Return, Enter, Space
            let opensHerdr = model.selectedRow != nil && model.selectedRow != AppModel.idleRow
            model.navigate(.activate)
            if opensHerdr { closeMenu() }
        case 46: model.navigate(.mute)        // M
        case 47, 51, 117: model.navigate(.dismiss)  // Full stop, Delete, Forward Delete
        case 53: closeMenu()                  // Esc
        default: return false
        }
        return true
    }

    // MARK: Menu

    /// Has the menu check its size whenever what it shows changes.
    private func trackMenuContent() {
        withObservationTracking {
            _ = (model.agents, model.showsIdle, model.listsIdle, model.rules, model.defaultRule, model.connection,
                 model.expandedRow, model.lastWords, model.dismissed, model.hidesMutedIn)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.trackMenuContent()
                for delay in [0.0, 0.05, 0.25] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.menu.remeasure()
                    }
                }
            }
        }
    }

    @objc private func toggleMenu() {
        if menu.isShown {
            menu.close()
            return
        }
        guard Date().timeIntervalSince(menu.lastClosed) > 0.25, let button = statusItem.button else { return }
        // Banners say what the menu is about to show.
        for notice in model.banners { model.dismiss(notice) }
        model.selectedRow = nil
        model.expandedRow = nil
        menu.show(below: button)
    }

    @objc private func closeMenu() {
        menu.close()
    }

    // MARK: macOS notifications

    /// Asks for permission the first time macOS notifications are chosen.
    private func trackNotifyStyle() {
        let style = withObservationTracking {
            model.notifyStyle
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackNotifyStyle() }
        }
        if style == .system, !DemoData.isOn {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func notify(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.userInfo = ["address": notice.agent.address]
        content.title = notice.title
        content.subtitle = notice.headline ?? notice.event
        content.body = notice.headline == nil ? (notice.excerpt ?? "") : notice.body
        if model.playsSound(for: notice) { content.sound = .default }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
    }

    /// Shows notifications even when Herdbar is the active app, and opens Herdr on a click.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let address = response.notification.request.content.userInfo["address"] as? String
        await MainActor.run { model.openHerdr(model.agents.first { $0.address == address }) }
    }

    // MARK: Quit and settings

    private func confirmQuit() {
        closeMenu()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Quit Herdbar?"
        alert.informativeText = "Its counts leave the menu bar and notifications stop until you open Herdbar again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func showSettings() {
        closeMenu()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
            window.title = "Herdbar Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        model.settingsPane = .general
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Self-check

    /// With HERDBAR_SNAPSHOT_DIR set, the app opens its menu, a banner and each settings page
    /// in turn and saves a PNG of each there. Combine with HERDBAR_DEMO for invented data.
    private func runSelfCheckIfAsked() {
        guard let directory = ProcessInfo.processInfo.environment["HERDBAR_SNAPSHOT_DIR"] else { return }
        let steps: [(String, () -> Void)] = [
            ("menu", { [weak self] in self?.toggleMenu() }),
            ("menu-expanded", { [weak self] in
                guard let self, let agent = self.model.agents.first(where: { $0.address == "t4" }) ?? self.model.sections.first?.agents.first else { return }
                self.model.selectedRow = agent.address
                self.model.expand(agent)
            }),
            ("menu-idle", { [weak self] in
                self?.model.expandedRow = nil
                self?.model.showsIdle = true
            }),
            ("settings-general", { [weak self] in self?.model.openSettings(.general) }),
            ("settings-notifications", { [weak self] in self?.model.openSettings(.notifications) }),
            ("settings-agents", { [weak self] in self?.model.openSettings(.agents) }),
        ]
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(index) * 3) { [weak self] in
                step.1()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let self else { return }
                    let view = step.0.hasPrefix("menu") ? self.menu.contentView : self.settingsWindow?.contentView
                    DebugLog.snapshot(view, to: "\(directory)/\(step.0).png")
                    if step.0 == "menu" {
                        // Whether the menu has the keyboard, and whether arrow keys reach it.
                        self.model.navigate(.down)
                        let report = "menu is key window: \(self.menu.window.isKeyWindow)\napp is active: \(NSApp.isActive)\nrows: \(self.model.navigableRows.count)\nselected after Down: \(self.model.selectedRow ?? "none")\n"
                        try? report.write(toFile: "\(directory)/keyboard.txt", atomically: true, encoding: .utf8)
                        self.model.selectedRow = nil
                    }
                }
            }
        }
        // The menu bar label and a banner, drawn straight to files.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let label = NSImageView(image: Self.label(self.model.counts, showsIdle: self.model.countsIdleInMenuBar))
            label.frame = NSRect(origin: .zero, size: label.image?.size ?? .zero)
            DebugLog.snapshot(label, to: "\(directory)/label.png")
            if let agent = self.model.agents.first(where: { $0.state == .needsYou }) {
                let notice = Notice(agent: agent, headline: "Run real sign-in checks after deploy",
                                    excerpt: "May I run the deploy script? It pushes the build to staging and then runs the sign-in checks against it.")
                let card = NSHostingView(rootView: BannerCard(notice: notice).environment(self.model).fontDesign(.rounded))
                card.frame = NSRect(origin: .zero, size: card.fittingSize)
                DebugLog.snapshot(card, to: "\(directory)/banner.png")
            }
        }
    }
}
