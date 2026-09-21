import AppKit
@preconcurrency import ApplicationServices

/// Reads every switchable window over AX and WindowServer.
@MainActor
enum WindowSwitchSweep {
    /// A sweep walks every app, so one hung process must not cost the full mover timeout.
    nonisolated private static let sweepTimeout: Float = 0.2
    nonisolated private static let remoteBudgetMilliseconds = 250.0
    nonisolated private static let anchoredRemoteBudgetMilliseconds = 500.0
    nonisolated private static let sourceRemoteBudgetMilliseconds = 2_000.0
    nonisolated private static let minimumServerWindowSize = CGSize(width: 80, height: 60)

    /// Live AX handles for one window. Never `Sendable`: these do not leave the main actor.
    struct Element {
        let app: NSRunningApplication
        let application: AXUIElement
        let window: AXUIElement
    }

    struct Application: Sendable {
        let pid: pid_t
        let appName: String
        let bundleID: String
        let iconURL: URL?
        let iconStamp: Int
        let appRank: Int
        let isSource: Bool
    }

    struct RemoteReference: Sendable {
        let pid: pid_t
        let windowID: UInt32
        let elementID: UInt64
    }

    struct Snapshot {
        var entries: [WindowSwitchEntry]
        var elements: [UInt32: Element]
        var applications: [Application]
    }

    struct RemoteSnapshot: Sendable {
        var entries: [WindowSwitchEntry]
        var references: [UInt32: RemoteReference]
    }

    private struct ServerWindow: Sendable {
        let pid: pid_t
        let windowID: UInt32
    }

    static func snapshot(ranks: [pid_t: Int], sourcePID: pid_t?) -> Snapshot {
        var entries: [WindowSwitchEntry] = []
        var elements: [UInt32: Element] = [:]
        var applications: [Application] = []

        for app in WindowInventory.candidates() {
            guard let bundleID = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            let application = AXWindowAccess.application(for: pid, timeout: sweepTimeout)
            let iconURL = app.bundleURL
            let iconStamp = iconURL.map(FileIconStamp.value(for:)) ?? 0
            let appName = app.localizedName ?? bundleID
            let appRank = ranks[pid] ?? .max
            var order = 0
            applications.append(
                Application(
                    pid: pid, appName: appName, bundleID: bundleID, iconURL: iconURL,
                    iconStamp: iconStamp, appRank: appRank, isSource: pid == sourcePID))

            func append(_ window: AXUIElement) {
                AXUIElementSetMessagingTimeout(window, sweepTimeout)
                guard isSwitchable(window), let windowID = AXWindowAccess.windowID(of: window),
                    elements[windowID] == nil
                else { return }
                entries.append(
                    WindowSwitchEntry(
                        windowID: windowID, order: order, appName: appName, bundleID: bundleID,
                        iconURL: iconURL, iconStamp: iconStamp,
                        title: AXWindowAccess.string(window, kAXTitleAttribute) ?? "",
                        isMinimized: AXWindowAccess.bool(window, kAXMinimizedAttribute) == true,
                        appRank: appRank))
                elements[windowID] = Element(
                    app: app, application: application, window: window)
                order += 1
            }

            for window in AXWindowAccess.windows(in: application) { append(window) }
            if let focused = AXWindowAccess.element(application, kAXFocusedWindowAttribute) {
                append(focused)
            }
            if let main = AXWindowAccess.element(application, kAXMainWindowAttribute) { append(main) }
        }
        return Snapshot(entries: entries, elements: elements, applications: applications)
    }

    nonisolated static func remoteSnapshot(
        applications: [Application], excluding knownWindowIDs: Set<UInt32>
    ) async -> RemoteSnapshot {
        let candidates = serverWindows(applications: applications, excluding: knownWindowIDs)
        let candidatesByPID = Dictionary(grouping: candidates, by: \.pid)

        return await withTaskGroup(of: RemoteSnapshot.self) { group in
            for application in applications {
                guard let candidates = candidatesByPID[application.pid], !candidates.isEmpty else {
                    continue
                }
                group.addTask {
                    let targetIDs = Set(candidates.map(\.windowID))
                    var windows = AXWindowAccess.remoteWindows(
                        for: application.pid, matching: targetIDs,
                        budgetMilliseconds: remoteBudgetMilliseconds, timeout: sweepTimeout)
                    var unresolved = targetIDs.subtracting(windows.map(\.windowID))
                    if !unresolved.isEmpty,
                        let anchor = AXWindowAccess.focusedElementID(
                            for: application.pid, timeout: sweepTimeout)
                    {
                        windows.append(
                            contentsOf: AXWindowAccess.remoteWindows(
                                for: application.pid, matching: unresolved,
                                budgetMilliseconds: anchoredRemoteBudgetMilliseconds,
                                timeout: sweepTimeout, startingAt: anchor, descending: true,
                                stride: 64))
                        unresolved = targetIDs.subtracting(windows.map(\.windowID))
                        if application.isSource, !unresolved.isEmpty {
                            windows.append(
                                contentsOf: AXWindowAccess.remoteWindows(
                                    for: application.pid, matching: unresolved,
                                    budgetMilliseconds: sourceRemoteBudgetMilliseconds,
                                    timeout: sweepTimeout, startingAt: anchor,
                                    descending: true))
                        }
                    }
                    var entries: [WindowSwitchEntry] = []
                    var references: [UInt32: RemoteReference] = [:]
                    for window in windows {
                        entries.append(
                            WindowSwitchEntry(
                                windowID: window.windowID, order: .max,
                                appName: application.appName,
                                bundleID: application.bundleID, iconURL: application.iconURL,
                                iconStamp: application.iconStamp, title: window.title,
                                isMinimized: window.isMinimized, appRank: application.appRank))
                        references[window.windowID] = RemoteReference(
                            pid: application.pid, windowID: window.windowID,
                            elementID: window.elementID)
                    }
                    return RemoteSnapshot(entries: entries, references: references)
                }
            }

            var result = RemoteSnapshot(entries: [], references: [:])
            for await partial in group {
                result.entries.append(contentsOf: partial.entries)
                result.references.merge(partial.references) { current, _ in current }
            }
            return result
        }
    }

    static func element(for reference: RemoteReference) -> Element? {
        guard let app = NSRunningApplication(processIdentifier: reference.pid), !app.isTerminated
        else { return nil }
        let application = AXWindowAccess.application(for: reference.pid, timeout: sweepTimeout)
        guard
            let window = AXWindowAccess.remoteWindow(
                for: reference.pid, elementID: reference.elementID,
                expectedWindowID: reference.windowID, timeout: sweepTimeout)
        else { return nil }
        return Element(app: app, application: application, window: window)
    }

    nonisolated private static func serverWindows(
        applications: [Application], excluding knownWindowIDs: Set<UInt32>
    ) -> [ServerWindow] {
        let pids = Set(applications.map(\.pid))
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard
            let listing = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }

        return listing.compactMap { raw in
            guard raw[kCGWindowLayer as String] as? Int == 0,
                let pid = raw[kCGWindowOwnerPID as String] as? NSNumber,
                let windowID = raw[kCGWindowNumber as String] as? NSNumber,
                pids.contains(pid.int32Value), !knownWindowIDs.contains(windowID.uint32Value),
                let bounds = raw[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], let height = bounds["Height"],
                width >= minimumServerWindowSize.width,
                height >= minimumServerWindowSize.height
            else { return nil }
            return ServerWindow(pid: pid.int32Value, windowID: windowID.uint32Value)
        }
    }

    private static func isSwitchable(_ window: AXUIElement) -> Bool {
        AXWindowAccess.string(window, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String)
    }
}
