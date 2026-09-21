import Foundation

/// The order an empty query shows: most recently used first, minimized windows last.
enum WindowSwitchOrder {
    static func merging(
        _ current: [WindowSwitchEntry], with additions: [WindowSwitchEntry],
        preferredWindowID: UInt32? = nil
    ) -> [WindowSwitchEntry] {
        var entries = Dictionary(uniqueKeysWithValues: current.map { ($0.windowID, $0) })
        for entry in additions where entries[entry.windowID] == nil { entries[entry.windowID] = entry }
        return sorted(Array(entries.values), preferredWindowID: preferredWindowID)
    }

    /// A total order, so the sort is deterministic however the sweep happened to enumerate apps.
    static func sorted(
        _ entries: [WindowSwitchEntry], preferredWindowID: UInt32? = nil
    ) -> [WindowSwitchEntry] {
        entries.sorted { left, right in
            if let preferredWindowID,
                (left.windowID == preferredWindowID) != (right.windowID == preferredWindowID)
            {
                return left.windowID == preferredWindowID
            }
            if left.isMinimized != right.isMinimized { return right.isMinimized }
            if left.appRank != right.appRank { return left.appRank < right.appRank }
            if left.appName != right.appName {
                return left.appName.localizedCaseInsensitiveCompare(right.appName)
                    == .orderedAscending
            }
            if left.order != right.order { return left.order < right.order }
            return left.windowID < right.windowID
        }
    }
}
