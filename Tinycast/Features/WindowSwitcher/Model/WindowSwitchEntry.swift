import Foundation

/// One open window the switcher offers. An id, not an `AXUIElement`: this layer stays pure.
struct WindowSwitchEntry: Identifiable, Hashable, Sendable {
    /// Stable across the AX and WindowServer paths for the life of the window.
    let windowID: UInt32
    /// The app's own front-to-back order; remote-only windows sort after its published ones.
    let order: Int
    let appName: String
    let bundleID: String
    let iconURL: URL?
    let iconStamp: Int
    let title: String
    let isMinimized: Bool
    /// Lower is nearer the front; `.max` when the app has no on-screen window to rank it by.
    let appRank: Int

    /// A string, because every palette list identifies its rows by one.
    var id: String { String(windowID) }

    /// A document window with no title yet reads as its app rather than as a blank row.
    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appName : title
    }

    // The app name rides as owner, not as a name: every window of one app shares it.
    func searchFields() -> SearchFields {
        [SearchAlias.name(displayTitle), SearchAlias.owner(appName)]
    }
}

struct WindowSwitchHistory: Sendable {
    private var sourceWindowID: UInt32?
    private var destinationPID: pid_t?

    mutating func record(sourceWindowID: UInt32, destinationPID: pid_t) {
        self.sourceWindowID = sourceWindowID
        self.destinationPID = destinationPID
    }

    mutating func preferredWindowID(currentPID: pid_t?) -> UInt32? {
        guard currentPID == destinationPID else {
            self = Self()
            return nil
        }
        return sourceWindowID
    }

    mutating func clear() { self = Self() }
}
