import SwiftUI

struct WindowSwitchScreen: PaletteScreen {
    let session: WindowSwitchSession
    let core: AppCore
    let metrics: InterfaceMetrics

    var rows: [WindowSwitchEntry] { session.filtered }

    var primaryActionTitle: String { "Switch to Window" }

    func hasActions(at selection: Int) -> Bool { false }

    func activate(at selection: Int) {
        guard rows.indices.contains(selection) else { return }
        core.windowSwitchCoordinator.activate(rows[selection])
    }

    func secondary(at selection: Int) -> Bool { false }

    func headerAccessory(
        at selection: Int, focus: FocusState<String?>.Binding
    ) -> PaletteHeaderAccessory? {
        PaletteHeaderAccessory(
            width: metrics.spacing.md + metrics.size.rowIcon,
            fieldNames: [], firstIncompleteField: nil,
            placement: .besideSearchField,
            view: AnyView(
                HStack(spacing: 0) {
                    Color.clear.frame(width: metrics.spacing.md)
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
                        .opacity(session.isDiscovering ? 1 : 0)
                        .accessibilityLabel("Discovering windows")
                        .accessibilityHidden(!session.isDiscovering)
                }))
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        if rows.isEmpty {
            EmptyResults(text: session.snapshot.isEmpty ? "No open windows" : "No windows found")
        } else {
            WindowSwitchList(
                entries: rows,
                selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                scroll: scroll,
                onActivate: { core.windowSwitchCoordinator.activate($0) })
        }
    }
}
