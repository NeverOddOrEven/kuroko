import AppKit
import ApplicationServices

/// Starts a Teams share of a display by pressing Teams' own meeting controls through the
/// Accessibility API. Teams has no API for this, so it relies on the DOM identifiers of Teams'
/// web UI (stable across languages) and on the share tray labelling screens by display name.
@MainActor
enum TeamsShareLauncher {
    enum Outcome: Equatable {
        case shared
        case needsAccessibility
        case teamsNotRunning
        case noMeeting
        case screenNotOffered
        case stopped
    }

    private static let teamsBundleID = "com.microsoft.teams2"
    private static let shareButtonID = "share-button"

    static func share(displayNamed name: String) async -> Outcome {
        // The literal value of kAXTrustedCheckOptionPrompt, a global that strict concurrency rejects.
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(prompt) else { return .needsAccessibility }
        guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: teamsBundleID).first else {
            return .teamsNotRunning
        }
        let app = AXUIElementCreateApplication(teams.processIdentifier)
        // Teams' web content builds its accessibility tree only once a client asks for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        if let tile = screenTile(named: name, in: app) {
            return press(tile)
        }
        guard let shareButton = first(in: app, where: { string($0, "AXDOMIdentifier") == shareButtonID }) else {
            return .noMeeting
        }
        AXUIElementPerformAction(shareButton, kAXPressAction as CFString)
        // The tray takes a moment to open and list the screens.
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if let tile = screenTile(named: name, in: app) {
                return press(tile)
            }
        }
        return .screenNotOffered
    }

    /// While sharing, Teams' Share button stops the share.
    static func stopSharing() -> Outcome {
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        guard let teams = NSRunningApplication.runningApplications(withBundleIdentifier: teamsBundleID).first else {
            return .teamsNotRunning
        }
        let app = AXUIElementCreateApplication(teams.processIdentifier)
        guard let shareButton = first(in: app, where: { string($0, "AXDOMIdentifier") == shareButtonID }) else {
            return .noMeeting
        }
        return AXUIElementPerformAction(shareButton, kAXPressAction as CFString) == .success ? .stopped : .noMeeting
    }

    private static func press(_ element: AXUIElement) -> Outcome {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? .shared : .screenNotOffered
    }

    private static func screenTile(named name: String, in app: AXUIElement) -> AXUIElement? {
        first(in: app) { string($0, kAXRoleAttribute) == kAXMenuItemRole && string($0, kAXValueAttribute) == name }
    }

    private static func first(in app: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        while !queue.isEmpty {
            let element = queue.removeFirst()
            if matches(element) { return element }
            queue += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }
}
