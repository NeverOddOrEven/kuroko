import AppKit
import KurokoCore

/// Status bar menu. Rebuilt each time it opens so it always reflects current state.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private static let friendlyNames = [
        "com.apple.notificationcenterui": "Notification Banners",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams (classic)",
    ]

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        // Items set isEnabled themselves; auto-enabling would override that.
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
    }

    func updateIcon() {
        let symbol = switch controller.state {
        case .live: "eye.slash"
        case .paused: "pause.circle"
        case .stopped: "stop.circle"
        case .starting: "hourglass"
        case .needsPermission, .failed: "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kuroko")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item("About Kuroko") { AboutPanel.show() })
        menu.addItem(.separator())
        menu.addItem(disabled(statusText))
        if controller.state == .needsPermission {
            menu.addItem(item("Open Screen Recording Settings…") { Permissions.openScreenRecordingSettings() })
            menu.addItem(item("Relaunch Kuroko") { [controller] in controller.relaunch() })
        }

        let isHalted = controller.state == .paused || controller.state == .stopped
        let pause = item(isHalted ? "Resume" : "Pause") { [controller] in controller.togglePause() }
        pause.keyEquivalent = "p"
        pause.keyEquivalentModifierMask = [.control, .option, .command]
        pause.isEnabled = controller.state == .live || isHalted
        menu.addItem(pause)
        menu.addItem(.separator())

        menu.addItem(submenu("Source Display", items: sourceItems()))
        menu.addItem(submenu("Excluded Apps", items: exclusionItems()))
        menu.addItem(submenu("Frame Rate", items: frameRateItems()))

        let preview = item("Show Preview") { [controller] in controller.setPreviewVisible(!controller.prefs.showPreview) }
        preview.state = controller.prefs.showPreview ? .on : .off
        menu.addItem(preview)

        let login = item("Launch at Login") { LoginItem.setEnabled(!LoginItem.isEnabled) }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = item("Quit Kuroko") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private var statusText: String {
        switch controller.state {
        case .starting: "Starting…"
        case .live: "Live — sharing \(sourceName) minus excluded apps"
        case .paused: "Paused — viewers see a frozen frame"
        case .stopped: "Stopped from the macOS menu bar — viewers see a frozen frame"
        case .needsPermission: "Needs Screen Recording permission"
        case .failed(let message): "Error: \(message)"
        }
    }

    private var sourceName: String {
        controller.sourceDisplayID.map(Displays.name(for:)) ?? "display"
    }

    private func sourceItems() -> [NSMenuItem] {
        controller.physicalDisplayIDs.map { id in
            let entry = item(Displays.name(for: id)) { [controller] in controller.selectSource(id) }
            entry.state = id == controller.sourceDisplayID ? .on : .off
            return entry
        }
    }

    private func frameRateItems() -> [NSMenuItem] {
        Preferences.frameRateOptions.map { fps in
            let title = fps == Preferences.defaultFrameRate ? "\(fps) fps (default)" : "\(fps) fps"
            let entry = item(title) { [controller] in controller.setFrameRate(fps) }
            entry.state = fps == controller.prefs.frameRate ? .on : .off
            return entry
        }
    }

    private func exclusionItems() -> [NSMenuItem] {
        let excluded = controller.prefs.excludedBundleIDs
        let listed = ExclusionMenu.listedBundleIDs(excluded: excluded)

        var items = listed.map { bundleID in
            let isExcluded = excluded.contains(bundleID)
            let entry = item(appName(for: bundleID)) { [controller] in controller.setExcluded(bundleID, !isExcluded) }
            entry.state = isExcluded ? .on : .off
            entry.toolTip = bundleID
            return entry
        }

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                app.bundleIdentifier.map { ExclusionMenu.App(bundleID: $0, name: app.localizedName ?? $0) }
            }
        let addable = ExclusionMenu.addableApps(running: running, listed: listed, selfBundleID: Bundle.main.bundleIdentifier)
        let addItems = addable.map { app in
            item(app.name) { [controller] in controller.setExcluded(app.bundleID, true) }
        }
        items.append(.separator())
        let add = submenu("Add Running App", items: addItems.isEmpty ? [disabled("No other apps running")] : addItems)
        items.append(add)
        return items
    }

    private func appName(for bundleID: String) -> String {
        if let name = Self.friendlyNames[bundleID] { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleID
    }

    // MARK: - Item builders

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, action: action)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        entry.submenu = sub
        return entry
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}
