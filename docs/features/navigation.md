# Navigation

Two commands that move you somewhere rather than changing something, behind one switch:
**Switch Windows** raises any open window of any running app, and **Search Menu Bar Items** presses
any item in the front app's menu bar. The second has its own page —
[menu-search.md](menu-search.md) — because its internals are a menu walk; this page owns the
switcher and the pane the two share.

Ships **off**. Settings › Navigation is the switch, and while it is off neither command is in the
launcher and a still-recorded shortcut for either does nothing.

## Invariants

- **The visible-Space sweep is synchronous; the other-Space sweep is bounded and concurrent.** The
  first opens the palette immediately from `AXWindows`, focused and main. The second asks WindowServer
  for missing ids, gives each app 250 ms on a task-group child, and gives the invoking app one deeper
  anchored pass for sparse ids. Only verified standard windows merge. A revision prevents stale results.
- **A live `AXUIElement` never crosses an actor and never outlives the show.** The background sweep
  returns only pid, WindowServer id, AX element id and row metadata. `WindowSwitchSession` retains live
  published elements and remote references `@ObservationIgnored`, and drops both in `reset()`.
- **Nothing in `Model/` knows what a window is.** `WindowSwitchEntry` takes `appRank` as a number
  someone else measured, so `WindowSwitchOrder` and `WindowSwitchQuery` stay Foundation-only and the
  harness compiles the shipped sources.
- **The order is total.** `(isMinimized, appRank, appName, appOrder, windowID)` — so a sweep that
  enumerated apps in a different order sorts identically, and minimized windows are always one run at
  the end rather than interleaved. Remote-only windows follow the app's published windows.
- **Accessibility is gated twice**, on show and again on activate: a grant revoked while the palette
  is open must not reach `AXUIElementPerformAction`.
- **Activation hides with `restoreFocus: false`.** Restoring focus reactivates the displaced app,
  which races the raise and can land on the wrong window — the same reason a Space command does it.
- **`AXWindowAccess` stays the one AX window layer.** `unminimize` and `focus` live there rather
  than in a second AX shim, and Window Layouts brings its frontmost window forward through `focus`.

## How it is put together

| Piece | Holds |
| --- | --- |
| `Model/WindowSwitchEntry.swift` | one row: WindowServer id, app order, title, minimized, rank, search fields |
| `Model/WindowSwitchOrder.swift` | the MRU sort, pure and total |
| `Model/WindowSwitchQuery.swift` | ranking over `SearchRelevance`, capped at 200 rows |
| `Service/WindowZOrder.swift` | the one `CGWindowList` call: per-pid front rank |
| `Service/WindowSwitchSweep.swift` | fast AX sweep, remote WindowServer sweep and element references |
| `Service/WindowSwitchSession.swift` | the observable state — snapshot, filtered rows, elements |
| `UI/WindowSwitchCoordinator.swift` | show, activate, the switch, the failure reports |
| `UI/WindowSwitchScreen.swift` | the `PaletteScreen` conformance and the two empty states |
| `UI/WindowSwitchList.swift` | the list and its row: app icon, title, app name |

## Recency without a private symbol

The MRU order comes from the window server's own front-to-back list: one
`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`, keeping
layer 0 — the normal window band, not the menu bar, Dock or overlay panels — and recording where each
pid first appears. Only `kCGWindowName` is permission-gated, and titles come from AX instead, so the
call needs no Screen Recording grant.

The rank is therefore **per app, not per window**. `_AXUIElementGetWindow` supplies the stable id that
joins published AX elements to WindowServer rows; the app's `AXWindows` order supplies its published
front-to-back order. An app with nothing on screen gets no rank and sorts after ranked apps by name.

The alternative was a long-lived activation observer with its own LRU and lifetime. This needs neither,
and it is right on the first summon after launch rather than after the user has switched apps once.

## The sweep

The fast sweep walks `WindowInventory.candidates()` — regular-policy, non-terminated, not us — and
merges `AXWindows`, `AXFocusedWindow` and `AXMainWindow`. The latter two are not hidden by the current
Space filter, so they recover one other-Space window from many apps at no extra round trip. Every row
must be an `AXStandardWindow`; minimized windows remain valid, and geometry is never required.

WindowServer's `.optionAll` list then names candidate ids absent from the fast result. A task-group
child per app walks remote AX element ids through `_AXUIElementCreateWithRemoteToken`, matches them back
with `_AXUIElementGetWindow`, and publishes only verified standard-window roots. Every app gets a 250 ms
low-id pass. The app that invoked the palette also exposes its focused element's remote token, so a
second pass walks backward from that live id for up to two seconds. This reaches long-lived Chromium
windows whose ids sit far beyond the low prefix without multiplying the deeper scan across every app.
The work remains concurrent and never delays the initial palette. A small header spinner stays visible
until the remote merge completes, making it clear that the first list is usable but not necessarily final.
Its slot remains reserved after completion, so the search field never moves. Live elements stay on main:
the worker returns the remote element id, and activation reconstructs and revalidates it before hiding
the palette. No Screen Recording grant is needed because titles come from AX rather than
`kCGWindowName`.

The app icon rides on the entry as a `FileIconStamp` and its bundle URL, and the row draws it through
`EntryIconView(source: .file(stamp:))` — so `IconCache` decodes once per app however many windows it
contributes.

## Raising

`activate` un-minimizes if it has to, raises the window inside its app, sets `AXFrontmost`, then calls
`NSRunningApplication.activate()`. All four steps are needed and none is redundant: the raise alone
orders the window inside an app that is not frontmost, and activating alone brings the app's *own*
front window forward rather than the chosen one. Activating is also what pulls another Space forward,
so the switcher needs no Space handling of its own.

Every step is allowed to fail quietly. What is reported is only the case the user can act on: the
window's app quit between the sweep and the ↵.

## Wiring

- **`CommandID.switchWindows`** (`command:switch-windows`) and `CommandID.searchMenuItems` are both
  named by `SettingsTab.navigation.ownedCommands`, which is the whole of what moves the second out of
  Settings › Commands: `LauncherItemsSection` filters on `settingsOwner == nil`, and `VisibilityStore`
  skips the `Enable Commands` category gate for a pane-owned command. Neither adds an
  `AppEntry.Kind`, a `HotKeyAction` case or a `VisibilityStore` category — they are plain `.command`
  entries.
- **`navigationEnabled`** (off) is the switch. `AppCore.observeFeatureSwitches` tracks it once and
  reprojects into both coordinators; each owns only its own command and its own palette mode, so
  neither knows about the other. `AppIndex.isCommandEnabled` feeds `hotKeys.allowsAction`, so both
  shortcuts go dead with the switch, and each `show()` re-guards the flag anyway.
- **`menuSearchDisabledApps`** (empty) is the exclusion list. It ships with no seeded entries, unlike
  the clipboard's: a menu read only ever happens because the user asked for one.
- **`menuSearchShowsAppleMenu`** (off) lists the Apple menu's own items. Off by default because that
  menu is identical under every app, so it would pad every snapshot with the same ~50 rows;
  [menu-search.md](menu-search.md) owns how it is applied.
- **Both ride in the pane's own `Search Menu Bar Items` section, beside the command row itself.**
  `FeatureCommandsSection` takes `excluding: [.searchMenuItems]` and the section draws that one
  command through `FeatureCommandRow`, so a command added to `ownedCommands` later still appears
  under `Commands` without a second edit. A list of excluded apps in a box of its own read as
  belonging to the pane rather than to one command, which is what this section exists to fix;
  `DisabledApplicationsList` is the shared half — the rows and the picker — that Settings ›
  Clipboard still wraps in a `DisabledApplicationsSection` of its own.
- Both settings ride in backups. Neither grants a permission class of its own — Accessibility is
  already required for paste — which is the call `windowManagementEnabled` made, and the opposite of
  `snippetsEnabled`.
- **There is deliberately no "Show in launcher" switch.** The per-command checkboxes in
  `FeatureCommandsSection` already are one, and a second would be a switch over rows the pane lists.

## Testing

`Tests/window-switch-test.swift` covers the pure half: the WindowServer-derived id, untitled-window
fallback, name/owner search fields, MRU order and totality, remote-result merging and deduplication,
the minimized run at the end, ranking, and the 200-row cap under empty and matching queries.

`WindowZOrder` and `WindowSwitchSweep` are not compiled into the harness and have no automated
coverage — the AX and `CGWindowList` paths need manual verification, particularly:

1. A minimized window is listed last and ↵ un-minimizes it rather than doing nothing.
2. A window on another Space is listed, and ↵ pulls that Space forward.
3. An app with several windows lists them in its own front-to-back order, under one app rank.
4. An app quit between the summon and the ↵ reports rather than failing silently.
