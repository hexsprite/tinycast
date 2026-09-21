import Foundation

@main
@MainActor
struct WindowSwitchTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func entry(
        _ windowID: UInt32, app: String = "Safari", title: String = "Window",
        minimized: Bool = false, rank: Int = 0, order: Int? = nil
    ) -> WindowSwitchEntry {
        WindowSwitchEntry(
            windowID: windowID, order: order ?? Int(windowID), appName: app,
            bundleID: "com.example.\(app.lowercased())",
            iconURL: nil, iconStamp: 0, title: title, isMinimized: minimized, appRank: rank)
    }

    static func main() {
        identity()
        displayTitle()
        searchMapping()
        history()
        ordering()
        orderingIsTotal()
        preferredWindow()
        merging()
        ranking()
        rankingLimit()

        print(failures == 0 ? "Window switch tests passed" : "\(failures) window switch tests failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func identity() {
        expect(entry(7).id == "7", "the id is the stable WindowServer id")
    }

    static func displayTitle() {
        expect(entry(0, title: "Notes.md").displayTitle == "Notes.md", "a titled window shows it")
        expect(
            entry(0, app: "Preview", title: "").displayTitle == "Preview",
            "an untitled window reads as its app rather than as a blank row")
        expect(
            entry(0, app: "Preview", title: "   ").displayTitle == "Preview",
            "a whitespace-only title is no title")
    }

    static func searchMapping() {
        let aliases = entry(0, app: "Safari", title: "Inbox").searchFields().aliases
        expect(
            aliases.contains { $0.text == "Inbox" && $0.role == .name },
            "the window title is the name a query matches")
        expect(
            aliases.contains { $0.text == "Safari" && $0.role == .owner },
            "the app rides as owner: every window of one app shares it")
    }

    static func history() {
        var history = WindowSwitchHistory()
        history.record(sourceWindowID: 7, destinationPID: 20)
        expect(
            history.preferredWindowID(currentPID: 20) == 7,
            "the source window is preferred while the destination app remains current")
        expect(
            history.preferredWindowID(currentPID: 21) == nil,
            "another current app clears the switch-back preference")
        expect(
            history.preferredWindowID(currentPID: 20) == nil,
            "a cleared preference cannot become stale when the old destination returns")
    }

    static func ordering() {
        let sorted = WindowSwitchOrder.sorted([
            entry(0, app: "Mail", rank: 2),
            entry(1, app: "Safari", minimized: true, rank: 0),
            entry(2, app: "Safari", rank: 0),
            entry(3, app: "Safari", rank: 0),
            entry(4, app: "Zed", rank: .max)
        ])
        expect(
            sorted.map(\.windowID) == [2, 3, 0, 4, 1],
            "front app first, then by rank, unranked next, minimized last: \(sorted.map(\.windowID))")
    }

    static func orderingIsTotal() {
        let entries = (0..<12).map {
            entry(
                UInt32($0), app: ["Mail", "Safari", "Zed"][$0 % 3],
                minimized: $0 % 4 == 0, rank: $0 % 3)
        }
        let once = WindowSwitchOrder.sorted(entries)
        let twice = WindowSwitchOrder.sorted(entries.reversed())
        expect(
            once.map(\.windowID) == twice.map(\.windowID),
            "the order is total, so a shuffled sweep sorts identically")
        expect(
            once.map(\.windowID).sorted() == entries.map(\.windowID).sorted(),
            "sorting drops nothing")
        let split = once.firstIndex(where: \.isMinimized) ?? once.count
        expect(
            once[split...].allSatisfy(\.isMinimized),
            "minimized windows form one run at the end, never interleaved")
    }

    static func preferredWindow() {
        let entries = [
            entry(1, app: "Current", rank: 0),
            entry(2, app: "Previous", minimized: true, rank: 1)
        ]
        expect(
            WindowSwitchOrder.sorted(entries, preferredWindowID: 2).map(\.windowID) == [2, 1],
            "the last source window becomes the default even when minimized")
        expect(
            WindowSwitchOrder.sorted(entries, preferredWindowID: 99).map(\.windowID) == [1, 2],
            "a missing preferred window leaves the normal order unchanged")
    }

    static func merging() {
        let current = [entry(7, app: "Safari", title: "Published", rank: 0)]
        let merged = WindowSwitchOrder.merging(
            current,
            with: [
                entry(7, app: "Safari", title: "Remote duplicate", rank: 0),
                entry(9, app: "Mail", title: "Other Space", rank: 1)
            ])
        expect(merged.map(\.windowID) == [7, 9], "remote windows merge into the sorted list")
        expect(merged[0].title == "Published", "a remote duplicate never replaces a live AX entry")

        let sameApp = WindowSwitchOrder.merging(
            [entry(90, order: 0)], with: [entry(1, order: .max)])
        expect(
            sameApp.map(\.windowID) == [90, 1],
            "a remote-only window follows the app's published front-to-back run")

        let preferredRemote = WindowSwitchOrder.merging(
            [entry(7)], with: [entry(9, rank: 1)], preferredWindowID: 9)
        expect(
            preferredRemote.map(\.windowID) == [9, 7],
            "a preferred window stays first when it arrives from remote discovery")
    }

    static func ranking() {
        let entries = [
            entry(0, app: "Mail", title: "Drafts"),
            entry(1, app: "Safari", title: "Inbox"),
            entry(2, app: "Safari", title: "Inbox archive")
        ]
        expect(
            WindowSwitchQuery.rank(entries, for: "").map(\.windowID) == [0, 1, 2],
            "an empty query keeps the order it was handed")
        expect(
            WindowSwitchQuery.rank(entries, for: "Inbox").first?.windowID == 1,
            "the exact title beats the one that only starts with it")
        expect(
            WindowSwitchQuery.rank(entries, for: "Safari").map(\.windowID) == [1, 2],
            "the app name matches every one of its windows, in the order given")
        expect(
            WindowSwitchQuery.rank(entries, for: "zzz").isEmpty,
            "a query nothing matches ranks nothing")
    }

    static func rankingLimit() {
        let entries = (0..<(WindowSwitchQuery.resultLimit + 50)).map {
            entry(UInt32($0), app: "Safari", title: "Tab \($0)")
        }
        expect(
            WindowSwitchQuery.rank(entries, for: "").count == WindowSwitchQuery.resultLimit,
            "an empty query is capped too, so a huge sweep never builds a huge list")
        expect(
            WindowSwitchQuery.rank(entries, for: "Tab").count == WindowSwitchQuery.resultLimit,
            "the cap holds under a query every row matches")
    }
}
