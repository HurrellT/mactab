# Application shortcuts

Status: application shortcuts with window cycling implemented and reviewed. Direct desktop mappings have been removed in favor of macOS's existing keyboard shortcut configuration. Animation skipping remains deferred.

## Behavior

Settings → Shortcuts… opens an application list with enable, edit, and remove controls. No bindings are installed by default. The shortcut activates its app from another app, or cycles to the next window when the target is already active. Separate rapid presses are processed sequentially with a bounded pending count, while held-key repeats are ignored. A single-window app wraps to its only window. Launch if closed is on by default and can be disabled per binding.

Initial activation honors the existing Remember setting. Cycling starts from actual focus and follows the minimized-window and all-Spaces preferences. Direct shortcuts do not open the overlay, wait for its presentation delay, or request thumbnails.

## Implementation

Versioned shortcut records live in the existing preferences and store a stable record ID, enabled flag, physical key code, normalized modifiers, and application destination. The destination uses a bundle identifier and bundle path, rather than a process ID or display name. For launch, resolve the saved bundle if it still matches or use `NSWorkspace` to resolve the identifier.

`KeyboardInterceptor` matches configured chords through its existing event tap. Recording suspends shortcut actions. Validation requires Command, Control, or Option and rejects duplicates and the existing Cmd+Tab/Cmd+grave controls. Explicit application chords take priority over overlay navigation; unmatched navigation keys retain their existing behavior. Other application and system conflicts cannot all be detected.

`DirectShortcutController` resolves applications, launches, and requests focus outside the event-tap callback. Running apps reuse `WindowService.focus`; closed apps launch asynchronously through `NSWorkspace`. Cancellation prevents queued stale operations from stealing focus after another action wins. Cached and final discovery callbacks cannot activate twice.

`WindowCycle` preserves stable identities when an app reorders its windows after focus changes. Only the last cycle is retained, capped at 64 identities and expired on access after 30 seconds. Larger window lists are fully processed without retaining that extra order list. App termination clears its identities. There are no timers, background discovery tasks, additional keyboard hooks, or synthetic keyboard events for application shortcuts.

## Removed desktop mappings

Use **System Settings → Keyboard → Keyboard Shortcuts → Mission Control** to configure native desktop switching. MacTab does not remap desktop shortcuts, inspect system hotkey settings, or synthesize desktop-switch events.

The version-1 preference decoder skips obsolete desktop records individually and retains supported application bindings, including their IDs and enabled states. Saving the application list writes only supported bindings. Unit tests cover migration from mixed application/desktop configurations.

## Deferred: Space animation feasibility

Do not implement this stage as part of application shortcuts. The current app leaves system animations unchanged and exposes no animation-skipping control. Retain the following research for a separate future branch.

Keep the distinction between reducing motion and skipping the transition. Apple's supported **Reduce Motion** setting changes desktop-transition effects, but does not promise zero animation or immediate focus. On macOS 27 it is under **System Settings → Accessibility → Motion**; earlier systems expose it under Display. A settings link and explanation are a useful fallback. MacTab already respects Reduce Motion for thumbnail fades. See Apple's [onscreen motion guidance](https://support.apple.com/guide/mac-help/customize-onscreen-motion-mchlc03f57a1/27/mac/27).

No supported public API for disabling the system Space-switch animation was identified. However, current yabai provides an implementation worth investigating: [instant Space switching with SIP enabled](https://github.com/asmvik/yabai/issues/2780) uses simulated high-velocity trackpad gestures, and its [focus-animation work](https://github.com/asmvik/yabai/issues/2781) extends that approach to app/window activation. Its [current option documentation](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc#global-settings) describes `skip_window_focus_animation`. This is evidence of feasibility in another app, not a compatibility guarantee for MacTab or macOS 27.

Investigate an isolated, on-demand backend using current [yabai Space-switching source](https://github.com/asmvik/yabai/blob/master/src/space_manager.c) as a reference. It relies on undocumented behavior and private system interfaces. Review the upstream license before reusing code. Preserve SIP and avoid privileged helpers, Dock injection, or an external daemon dependency. Focus the prototype on activating an app or window on another Space; direct desktop switching is outside MacTab’s scope.

If the prototype succeeds, expose **Skip Space-switch animations (experimental)**, off by default. Apply it only to MacTab-initiated app and window switches that are verified to work with this backend; describe any narrower supported scope in Settings. Keep native behavior as the fallback for unsupported OS versions or unavailable private symbols. Avoid a second transition after a partially completed attempt: first determine whether the destination was reached. Do not change global animation preferences or intercept every system Space change.

If skipping animations requires continuous monitoring, cannot reliably preserve focus, or fails the resource budget, leave it out of the release and offer the Reduce Motion settings link. Do not ship a toggle that merely renames reduced motion as disabled animation.

## Validation

Tests cover shortcut matching, repeat suppression, recording, interruption, Cmd+Tab repeat behavior, preference persistence and migration, rapid application presses, stable window cycling, single-window wrapping, cancelled discovery/launch, changed destinations, and closed apps with launching disabled.

Manually validate remembered windows, minimized windows, and cross-Space focus in target applications before release. For a future animation prototype, test each supported OS/architecture and multiple displays separately. Compare idle CPU/wakeups and retained memory with the current build; keep one event tap and no polling, screenshot preloading, external daemon, or per-shortcut shell process.
