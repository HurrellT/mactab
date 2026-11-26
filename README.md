# MacTab

A small native macOS app switcher with an optional window row. Built with Swift and AppKit, with no third-party dependencies. Focused on maximum performance. Requires macOS 14 or later.

## Build and run

```sh
./scripts/build.sh
open build/MacTab.app
```

On first launch, use **Enable Accessibility…** in Settings and allow MacTab in **System Settings → Privacy & Security → Accessibility**. Return to MacTab and click **Check permissions**. The button recreates the keyboard hook, verifies that it is enabled, and displays the result with recovery steps. The standard macOS switcher remains available until MacTab can intercept the shortcut.

### If MacTab is enabled in Accessibility but does not work

The locally built app is ad-hoc signed. A code change changes its signing requirement, and an old permission entry can still look enabled even when macOS reports the current app as untrusted.

1. Build first, then open `build/MacTab.app`.
2. In System Settings → Privacy & Security → Accessibility, remove the old MacTab entry with **−**.
3. Add the current `build/MacTab.app` with **+**, and enable it. In the file picker, Command + Shift + G lets you enter the full app path shown by **Check permissions**.
4. Use **Relaunch** in MacTab, then **Check permissions**. A successful check confirms Accessibility and an enabled keyboard hook.

If Accessibility is granted but the keyboard hook fails, the check explains whether Input Monitoring also needs attention. Secure Keyboard Entry can prevent input delivery even with a working hook; MacTab reports that condition separately. Paused and demo modes are also identified explicitly.

To keep grants across code changes, follow the [stable signing setup](docs/SIGNING.md) for a local certificate or an Apple-issued identity. Save its name or fingerprint in `.signing-identity`, or supply `MACTAB_SIGN_IDENTITY` when building. Changing the identifier or weakening the signing requirement is not a substitute. Screen Recording grants can also become stale after an ad-hoc rebuild; **Check permissions** checks that grant separately.

The app lives in the menu bar. Its application icon uses the same overlapping-window symbol as the menu bar. Use its menu to open Settings, disable it, or quit. To run at login, add the built app under System Settings → General → Login Items. Keep the app at a stable path; if you move it, update its permission entry.

## Free prebuilt sharing

Run `./scripts/build.sh --universal` and `./scripts/package.sh` to create a ZIP for Apple Silicon and Intel Macs. Recipients extract it and run `./install.sh --allow-unnotarized`; they need neither Xcode nor a paid developer account. This command explicitly permits the unnotarized app by removing quarantine from MacTab only. Accessibility and Screen Recording are still granted manually, and ad-hoc updates may require refreshing those grants. See [sharing instructions](docs/SHARING.md) for packaging, checksums, backups, and optional recipient signing.

## Controls

| Shortcut | Action |
| --- | --- |
| Hold Command, press Tab | Show apps and select the previous app |
| Command + Tab / Shift + Command + Tab | Next / previous app; collapse window row |
| Command + ` from outside the switcher | Open only the current app's windows; press again to cycle |
| Command + ` during Command + Tab | Expand the highlighted app's windows; press again to cycle |
| Shift + Command + ` | Cycle windows backward after expansion |
| Left / Right | Select within the active row |
| Down / Up | Expand / collapse windows |
| Release Command or press Return | Activate selection |
| Escape | Cancel |
| Click an app or window | Activate it |

The grave shortcut uses the physical key above Tab (key code 50), as on a US keyboard. Hold Command to keep either switcher open. With **Remember the last focused window** enabled, the standalone window switcher orders visited windows by recent focus: its first press selects the previously viewed window, including one on another Space when **Show windows from all Spaces** is enabled. Quick taps toggle between the two most recently focused windows; holding Command keeps that session's order stable for cycling through the remaining windows. With remembering off, the first press advances from the actual focused window in the app's enumeration order. Shift reverses this initial step. Repeated grave presses or arrows cycle windows; releasing Command activates the selection. Command + Tab from this mode starts the usual app switcher. Up collapses windows only in the app switcher.

Both switchers wait 100 ms before appearing, so quick taps activate the selection without flashing the overlay. Selection and window discovery start immediately; only presentation is delayed. Thumbnail capture starts once the overlay is visible. The delay uses a cancellable, one-shot callback with no idle polling.

## Preferences

- **Remember the last focused window** (on): track the last focused window for each running app, including focus changes outside MacTab. App-only switching restores it; expanding the row preselects it. Memory lasts for the process lifetime and is cleared when the target app exits. When off, app-only switching uses the app's normal activation behavior, and the window row starts with the first AX window.
- **Include minimized windows** (on): selecting a minimized window restores it.
- **Show windows from all Spaces** (on): combine the WindowServer inventory with Accessibility windows, including other Spaces and fullscreen windows. Turn it off to retain the original current-Spaces list, including covered and minimized windows exposed by the app. Other-Space windows are identified on their cards.
- **Show keyboard hints in the switcher** (on): turn it off to hide the shortcut footer in both rows and shrink the overlay. Keyboard controls continue to work.
- **Window thumbnails** (off): optional Screen Recording permission. Only visible window cards receive small, on-demand still images. New previews use a 120 ms native [Core Animation crossfade](https://developer.apple.com/documentation/quartzcore/catransition), disabled with Reduce Motion. Scrolling retains overlapping visible previews and captures only missing images, keeping the six-image limit. No capture stream, background recording, or disk storage. Without permission, cards show the app icon, window title, and display instead.

## Liquid Glass appearance

MacTab supports the system Liquid Glass appearance settings on **macOS 27** through AppKit's native glass surface. Adjust the Liquid Glass slider under **System Settings → Appearance** to choose the amount of transparency and tinting. There is no separate glass preference in MacTab. The overlay keeps its dark appearance for contrast over light windows; the system glass setting controls its material treatment. See Apple's [Appearance settings](https://support.apple.com/guide/mac-help/change-appearance-settings-mchlp1225/27/mac/27) and [Liquid Glass accessibility guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

Native Liquid Glass is also used on macOS 26. macOS 14 and 15 use the older visual-effect material.

## Direct application shortcuts

Open **Settings → Shortcuts…** to add, edit, enable, or remove an application shortcut. No bindings are installed by default. Record a chord containing Command, Control, or Option; Escape cancels recording. Bindings use physical keys, like the main switcher. Duplicate chords and the existing Command-Tab/Command-grave shortcuts are rejected. Other applications and macOS can still reserve conflicting shortcuts.

Choose an application bundle. From another app, the shortcut activates it and honors **Remember the last focused window**. While the target app is active, each press advances to its next window, wrapping around. Window cycling follows the minimized-window and all-Spaces preferences and keeps a stable order even when the app reorders its windows after activation. **Launch if closed** is on by default and can be disabled for each binding. Held-key repeats do not cycle; separate rapid presses are queued. Direct shortcuts do not open the overlay or load thumbnails.

These bindings share the existing keyboard hook, are suspended while recording a shortcut, and stop when MacTab is disabled. Window discovery happens only when cycling; there is no idle polling, second keyboard hook, or screenshot preloading. Older saved desktop mappings are ignored while application bindings are retained. Configure desktop shortcuts directly in **System Settings → Keyboard → Keyboard Shortcuts → Mission Control**.

Space animations continue to use macOS's system behavior. An option to skip animations when focusing an app or window on another Space remains **deferred**; see the [implementation notes and future animation plan](docs/SHORTCUTS_PLAN.md).

## Architecture and performance

macOS has no public extension point for the system Command-Tab UI, so MacTab supplies its own nonactivating AppKit overlay and intercepts Command-Tab and Command-grave with a session event tap. Other keyboard events pass through outside a switching session.

On macOS 26 or later the overlay uses AppKit's native [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), with regular glass and a dark appearance for contrast over light windows. Older versions use NSVisualEffectView. Icons render without vibrancy, selection uses a neutral highlight, and only the selected app shows its name. A single glass surface covers either layout.

The app row grows to the display's available width (with 24-point side margins). Icons stay at their 96-point maximum until the row fills the display, then shrink proportionally so every app remains visible without an app scrollbar. The window row can still scroll horizontally.

The app list comes from NSWorkspace, ordered by app activations observed since launch (the remaining apps start alphabetically). The idle app uses workspace notifications and an AX observer for only the frontmost app. There are no polling timers. WindowServer enumeration happens only when expanded. Small AX references acquired on activation are retained by process/window ID so visited windows remain selectable across Spaces; they are pruned against the next inventory and cleared when the app exits. Focus-change notifications read only the focused window; activation also seeds the app's other published windows.

Repeated window-switcher openings reuse a metadata snapshot for the last expanded app, capped at 64 windows. Larger lists are fully enumerated without caching or truncation. A snapshot expires after 30 seconds, checked on the next access, and is discarded on app termination or an incompatible app, window inventory, visibility preference, or display configuration. Before showing cached cards, MacTab checks the live window inventory and actual focused window. Excluding minimized windows also checks their current minimized state so restoring a window cannot leave it out of the cycle. Titles, geometry, and minimized state refresh once on opening, with batched Accessibility reads; selection and displayed order remain stable during that refresh. Closed cached targets are validated before activation. There is no background discovery or thumbnail preloading. Icons and thumbnails are released after each session; capture waits for fresh metadata and is cancellable, limited to six visible cards at up to 480 × 320 pixels each.

The all-Spaces route queries [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)) with `.optionAll`. Since `AXWindows` can omit other-Space roots, `CrossSpaceAccessibility.swift` dynamically resolves `_AXUIElementGetWindow` and `_AXUIElementCreateWithRemoteToken`. Recovery runs only for missing IDs in the selected app, off the main thread, with a 200 ms scan budget and a 20 ms per-request timeout. An unchanged unresolved inventory is retried at most once every five seconds when opening the switcher; new missing IDs trigger an immediate attempt, and explicit activation can retry its selected ID. Later scans resume past already-probed IDs. Normal AX requests, including child windows and menus, use a 150 ms timeout; a slow request can overrun a scan budget by its timeout. These two private bridges can change with macOS releases and are not suitable for a Mac App Store build. The rest of window activation uses public AX raise/press actions. An app's native Window-menu entries provide a fallback when available, including when WindowServer redacts titles without Screen Recording permission.

## Current limits

- Some custom windows, protected content, or nonstandard apps may not provide usable titles, geometry, previews, or focus actions. WindowServer-only entries are still listed, but an unvisited window that has neither a recoverable AX root nor an unambiguous native Window-menu entry may not activate. Visiting that Space seeds the AX reference cache. WindowServer can also report stale windows on some macOS versions; cached invalid AX roots are rejected.
- Window focusing across Spaces and fullscreen apps depends on macOS and the target app. MacTab raises the selected AX window and activates its app; it does not manipulate Spaces with private APIs.
- If Command is released while windows are still loading, the overlay closes immediately and activation waits for that result. Any window-navigation presses made during loading are preserved. Starting a new switching session cancels the pending activation.
- Window previews match ScreenCaptureKit windows by window ID, or by title/bounds when no ID is available. Ambiguous, menu-only, or minimized windows use the icon fallback. Minimized status is known for AX-backed windows; a WindowServer-only window may not expose that state.
- The build script creates a locally ad-hoc-signed app, not a notarized distribution. Rebuilds may require refreshing privacy permissions. Set `MACTAB_SIGN_IDENTITY` to a stable signing identity when available.
- A short local idle sample on macOS 26.6.2 / Apple Silicon reported 0.0% CPU and about 22 MB in `top`'s MEM column (about 53 MB RSS). This was after opening and closing Settings, with Accessibility ungranted and thumbnails disabled; it is a baseline, not a measurement of active switching. Permission-enabled idle, active-switching measurements, and multi-display Chrome validation are still needed.

A read-only Chrome discovery benchmark on 2026-10-07 compared the previous service with this cache implementation. Across seven consecutive warm requests, median time to window metadata fell from 207.1 ms to 1.5 ms; full refresh time fell to 6.2 ms, and CPU time in the benchmark process fell from 46.1 ms to 1.6 ms per request. Both versions returned the same three window IDs. Cold discovery remained about 225 ms. The cached card payload estimate was 394 bytes, excluding AX objects, inventory sets, and allocator overhead. Benchmark RSS was approximately 31.6 MiB before and 31.8 MiB after; this short sample does not establish an exact RAM cost. These measurements exclude overlay drawing, thumbnails, focus actions, and macOS Space-transition animations.

## Development

```sh
swift test
swift build
# Regenerate the bundled app icon from the menu bar SF Symbol (only when changing the asset):
swift scripts/generate-app-icon.swift
# Print permission and keyboard-hook state for a terminal-launched process:
build/MacTab.app/Contents/MacOS/MacTab --diagnostics
# Always show Settings (including when already authorized):
open build/MacTab.app --args --settings
# Inspect the native UI without permissions or shortcut interception:
open build/MacTab.app --args --demo
open build/MacTab.app --args --demo-expanded
open build/MacTab.app --args --demo-expanded --hide-hints
open build/MacTab.app --args --demo-windows
open build/MacTab.app --args --demo --many-apps
# Automatically exit a demo after two seconds:
build/MacTab.app/Contents/MacOS/MacTab --demo-expanded --smoke-test
```

The demo shows sample window titles with installed application icons. It does not focus or capture other windows. Tests cover app and standalone-window selection behavior and permission states, including revoked grants, disabled taps, Secure Keyboard Entry, paused mode, and demo mode.

To measure window discovery, quit MacTab and launch `open build/MacTab.app --args --window-timing`. View the opt-in logs with `log stream --level info --predicate 'subsystem == "com.tlh.mactab" AND category == "window-discovery"'`. They report cached-card latency, full refresh time, window counts, and an estimated metadata payload size. The estimate excludes opaque AX objects and allocator overhead; it is not a process RAM measurement. Window titles are not logged. Timing logs are disabled during normal use.

macOS can attribute privacy access for a terminal-launched process to its launcher. Prefer **Check permissions** in the app opened with `open build/MacTab.app` when diagnosing its normal launch; a terminal diagnostic may report different grants.

Public APIs: [CGEvent taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)), [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement), [AXObserver](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate), and [ScreenCaptureKit still captures](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager).
