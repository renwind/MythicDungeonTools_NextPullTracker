# Changelog

All notable changes to this project are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Per-NPC notes: middle-click a beacon portrait to attach a note to that mob kind (save / cancel / clear popup). Notes are account-wide, keyed by NPC id (name as fallback), survive across pulls and dungeons, and support WoW colour escapes (`|cffFF4040text|r`). Annotated mobs show a gold line under the name in the portrait tooltip and a gold dot on the portrait corner. An optional "Show Notes" toggle (right-click menu / settings, `beacon.showNpcNotes`, off by default) adds up to 8 note strips above the beacon listing each annotated mob in the current pull — left icon, truncated single-line note, full text on hover.

- Optional light-gray minimap dots for dungeon monsters that are not selected in any pull of the route. The color and opacity can be customized in Pull Colors.

## [1.4.5] - 2026-08-12

### Fixed

- Addon running wrong dungeon on challenge start

## [1.4.4] - 2026-08-12

### Fixed

- Bundled the AceDB-3.0 runtime and its required libraries so the addon can initialize its saved variables without depending on another addon to provide AceDB.
- Restored compatibility with MDT 6.2, which moved its implementation into a private addon namespace and removed the legacy global `MDT` table.
- Replaced the removed `MouseIsOver` global with WoW 12.1's region method so Beacon hover controls and the resize grip no longer raise Lua errors.
- Updated specialization-role detection for WoW 12.1's `C_SpecializationInfo` API so tanks are still recognized during automatic startup.

## [1.4.2] - 2026-08-12

### Changed

- Updated the WoW interface version for compatibility with WoW 12.1.

## [1.4.1] - 2026-06-10

### Fixed

- The beacon's Skip Pull and Revert Pull hover buttons work again. They still referenced the parent MDT addon's namespace (a leftover from when this code lived in an MDT fork), so clicking them silently did nothing; they now route to the tracker's own `SkipTo` / `MarkIncomplete`.
- `/npt status` no longer shows a mob kill counter that was always 0 mid-pull (per-mob kills aren't observable without the combat log); it now shows the pull's mob total alongside the forces progress.

### Removed

- Dead code swept out: the unused `npcIdToPulls` / `seenGUIDs` tracking state, the unused `dimUpcoming` / `highlightColor` saved-variable defaults, an unreachable `LiveSession_SendPullStates` call into stock MDT, and an unloaded duplicate of `Mdt.lua` under `Utils/`.

## [1.4.0] - 2026-05-08

### Added

- "Map Only" mode: a toggle that hides the beacon's info panel (pull header, mob count, portraits, progress bar, upcoming preview) and shrinks the beacon down to just the minimap. Available as a checkbox in the settings panel and in the beacon's right-click menu. Stored in `beacon.mapOnly` (off by default), applied on every Show via the new `BeaconFrame.applyLayoutMode`.

## [1.3.0] - 2026-05-08

### Added

- Customizable pull colors ("Pull Colors" section in the settings panel): color pickers (with opacity) for the minimap pull dots and the outline drawn around the current pull, which are now independently colorable. The current pull (next and active) each gets a separate Dots and Outline color; the upcoming pull gets a Dots color; completed pulls keep their fixed gray. A small minimap-style preview shows the result live, and a "Reset to Defaults" button restores the palette. Dot colors are stored in `beacon.pullColors` (read by `colorForPullState`) and outline colors in `beacon.pullOutlineColors` (read by the new `outlineColorForPullState`). Defaults match the previous palette (next=green, active=orange, completed=gray, upcoming=yellow).

## [1.2.0] - 2026-05-08

### Added

- Settings panel registered with Blizzard's native UI (Esc → Options → AddOns → "MDT Next Pull Tracker"). Open it from the right-click menu on the beacon, with `/npt settings`, or via the new "Open Settings" key binding. Surfaces every existing toggle (master enable, auto-start, lock, show upcoming, show for non-tanks, ask on start) plus a new opacity slider and a "Per Character / Account-wide" scope dropdown — settings that previously lived only in `SavedVariables` and the right-click menu.
- Beacon opacity setting (`beacon.alpha`, 30%–100%): applied with `SetAlpha` on the parent frame so the whole HUD fades uniformly. Persists alongside the other beacon prefs.
- "Reset Position & Size" entry in the beacon's right-click menu: re-anchors the beacon to its default top-center spot and clears any saved scale, without touching the lock state.
- Key bindings under WoW's Esc → Key Bindings → Addons (header "MDT Next Pull Tracker"): Toggle Beacon, Next Pull, Previous Pull, Toggle Lock, Open Settings. The Next/Previous bindings reuse the same logic as the on-beacon control buttons, so step-forward/back works without aiming the cursor.
- Right-click "Open Settings" entry on the beacon as a discoverability bridge from the context menu to the new panel.
- Mob name tooltip on portrait hover: hovering an enemy portrait on the beacon now surfaces the mob's localized name via the standard `GameTooltip`, so you can identify which mob is which without having to recognize every model. A transparent hover region is overlaid on each portrait (textures don't receive mouse input on their own).

### Fixed

- `Bindings.xml` is now auto-loaded from the addon root and no longer referenced from the TOC, and the bogus `xmlns` declaration on the `<Bindings>` root has been removed. Listing it under `Core.lua` routed it through the generic XML loader (which expects a `<Ui>` root) and produced "Couldn't open Bindings.xml"; the namespace mis-attribution made WoW treat each `<Binding>` as an unknown element from the Ui namespace.
- Section header (`MDTNPT_HEADER`) is now declared on the first binding only, rather than on every binding. WoW registers the header from each `<Binding>` that carries the attribute, so duplicating it raised "Binding header MDTNPT_HEADER was attempted to be loaded more than once" once per extra binding.

## [1.1.7] - 2026-05-08

### Added

- Resizable beacon: drag the WoW-style resize grabber in the bottom-right corner to scale the whole beacon up or down (uniform scale, clamped to 0.5×–2×). The chosen size persists per scope (account-wide or per-character, matching the existing `beaconScope` setting). Drags are blocked while the beacon is locked.

### Fixed

- Beacon now closes automatically when the keystone is reset via the vote-to-abandon. Previously only `CHALLENGE_MODE_COMPLETED` (timed-out / finished runs) stopped tracking, so an aborted key left the beacon and tracking state visible until manually dismissed. `CHALLENGE_MODE_RESET` now routes through the same `Stop()` path.

## [1.1.6] - 2026-04-22

### Fixed

- Boss pulls are no longer auto-skipped before the boss is actually dead. Bosses usually contribute 0 enemy forces, so the previous 0-forces auto-skip would collapse a boss pull the moment forces from the preceding trash pull overflowed into it. Boss pulls now wait for the scenario boss-kill criterion to fire before advancing, including when the boss dies in the same update as surrounding trash (the pending kill carries forward so the pull advances cleanly once the consume loop reaches it).
- Over-planned trash pulls now auto-complete when scenario forces cap at 100%. MDT routes often allocate more forces to the last trash pull before a boss than are actually needed to reach the dungeon max, and Blizzard stops reporting kills once the cap is hit — so the pull could never finish via the delta path and the beacon stayed stuck. On reaching 100%, remaining non-boss pulls advance through to the next boss pull.

## [1.1.5] - 2026-04-21

### Added

- Manual mini-map zoom on the Next Pull beacon: scroll the mouse wheel over the mini-map, or click the on-screen `+` / `-` buttons, to zoom in past the adaptive default or zoom out for more context.
- Outline drawn around the current pull on the mini-map, wrapping the enemy cluster's actual shape (convex hull). The outline color tracks the pull state (green = next, orange = in combat).

### Changed

- Mini-map enemy dots now render at a consistent size across pulls; the current pull is distinguished by the new outline rather than by dot size.
- Beacon pull badge now shows progress as `Pull X / Total` (e.g. `Pull 3 / 10`) instead of just the current pull number.
- Beacon layout refresh: mob portraits are larger (34px vs 22px), spaced further apart, rendered as circles with a thin white outline; the progress bar is now anchored at the bottom of the beacon with the "upcoming" preview sitting just above it.
- Mob portraits now adapt to pulls with 5+ distinct mob types: the row shrinks to a 2×4 grid of 28×28 portraits (instead of silently dropping the overflow), up to 8 total. Pulls with 4 or fewer still render as a single row of 34×34.

### Fixed

- Scenario tolerance check is now strict (`>`, previously `>=`): since Blizzard's floor-rounded integer percentages lag actual kills by strictly less than 1% of `dungeonMax`, a gap of _exactly_ 1% is a real deficit and should not auto-complete the pull.
- `/npt show` now re-enables the beacon after it was dismissed via the right-click "Hide Beacon" option (which persists `db.beacon.enabled = false`). Previously the beacon would re-hide on the next update, leaving the user with no way to bring it back without editing saved variables. `/npt hide` now mirrors the right-click behavior by also disabling the preference.
- Mini-map pan is now clamped to the map's bounds so pulls near an edge no longer leave black bars on the top/bottom/left/right of the viewport. When the zoomed map is smaller than the viewport on an axis (e.g. height at whole-map zoom on 15×10 maps), the container is centered on that axis.

## [1.1.4] - 2026-04-20

### Fixed

- Scenario rounding tolerance now matches Blizzard's up-to-1% floor-rounding error (was 0.5%), so the "next pull" indicator no longer stalls at the tick boundary on pulls that end at a high-fraction percentage.

## [1.1.3] - 2026-04-20

### Fixed

- Fallback to english when language is not covered by locales file

## [1.1.2] - 2026-04-20

### Added

- French (`frFR`) translation.

## [1.1.1] - 2026-04-20

### Added

- Russian (`ruRU`) translation.

## [1.1.0] - 2026-04-20

### Added

- Non-tank opt-in prompt on Mythic+ start, with a "Never ask" option that persists.

### Changed

- Adaptive mini-map zoom: each pull is framed to its own bounding box, so dungeons with wide pulls (e.g. Magisters' Terrace) no longer render off-screen or feel zoomed out.

### Fixed

- Beacon position now saves on drag-end, so a disconnect or crash mid-session no longer loses a position you just moved it to.

## [1.0.0] - 2026-04-20

Initial release.

### Added

- Scenario-based next-pull tracking (no combat-log dependency).
- Heads-up Beacon with mini-map preview, enemy portraits, and a live forces bar.
- Upcoming-pull preview.
- Per-character or account-wide Beacon position.
- Manual controls: mark complete, skip to pull, revert.
- Auto-start on Mythic+ key start, auto-stop on key end.
- Auto-sync MDT's selected dungeon to the player's zone on start, so auto-start and `/npt start` pick up the right route without switching dungeon manually in MDT. Falls back to the MDT-selected preset when the zone isn't a known dungeon.
- One-shot migration of Next Pull settings from the parent MDT addon.
- Slash commands: `/npt start|stop|skip|complete|status|info`.
- Retail (Midnight / 12.0) support.
