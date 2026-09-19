import Foundation

@MainActor
@Observable
final class WindowSwitchSession {
    private(set) var snapshot: [WindowSwitchEntry] = []
    /// The rows the list reads: ranked once per query change, so one keystroke ranks once.
    private(set) var filtered: [WindowSwitchEntry] = []

    private var query = ""
    private var revision = 0
    /// Live AX handles, so they are never observed and never outlive the show.
    @ObservationIgnored private var elements: [UInt32: WindowSwitchSweep.Element] = [:]
    @ObservationIgnored private var remoteReferences: [UInt32: WindowSwitchSweep.RemoteReference] = [:]

    @discardableResult
    func present(_ snapshot: WindowSwitchSweep.Snapshot) -> Int {
        revision &+= 1
        self.snapshot = WindowSwitchOrder.sorted(snapshot.entries)
        elements = snapshot.elements
        remoteReferences = [:]
        applyQuery()
        return revision
    }

    func merge(_ remote: WindowSwitchSweep.RemoteSnapshot, revision: Int) -> Bool {
        guard revision == self.revision else { return false }
        let existingIDs = Set(snapshot.map(\.windowID))
        for entry in remote.entries where !existingIDs.contains(entry.windowID) {
            if let reference = remote.references[entry.windowID] {
                remoteReferences[entry.windowID] = reference
            }
        }
        snapshot = WindowSwitchOrder.merging(snapshot, with: remote.entries)
        applyQuery()
        return true
    }

    func element(for windowID: UInt32) -> WindowSwitchSweep.Element? {
        if let element = elements[windowID] { return element }
        guard let reference = remoteReferences[windowID] else { return nil }
        return WindowSwitchSweep.element(for: reference)
    }

    func entryID(at index: Int) -> WindowSwitchEntry.ID? {
        filtered.indices.contains(index) ? filtered[index].id : nil
    }

    func index(ofEntryID id: WindowSwitchEntry.ID) -> Int? {
        filtered.firstIndex { $0.id == id }
    }

    func reset() {
        revision &+= 1
        snapshot = []
        filtered = []
        elements = [:]
        remoteReferences = [:]
        query = ""
    }

    func filter(_ query: String) {
        self.query = query
        applyQuery()
    }

    private func applyQuery() {
        filtered = WindowSwitchQuery.rank(
            snapshot, for: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
