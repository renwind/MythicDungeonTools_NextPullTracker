## Mythic Dungeon Tools - Next Pull Tracker

A companion AddOn for [Mythic Dungeon Tools](https://www.curseforge.com/wow/addons/mythic-dungeon-tools) that tracks your progress through an MDT route live while you are in a Mythic+ key.

## Description

Mythic Dungeon Tools lets you plan pulls on a map. This AddOn takes the next step: while you are running the key, it watches scenario forces, figures out which pull of your route is the one the tank is about to grab, and surfaces that to your UI. Healers and DPS always know which group is coming next without having to read the MDT window.

Tracking starts automatically the moment the Mythic+ key begins — no slash command or button press required — and stops on its own when the key ends.

Requires Mythic Dungeon Tools to be installed and enabled.

## Features

- Scenario-based pull tracking — advances the "next pull" indicator from enemy forces progression, no Combat Log dependency
- Heads-up Beacon with a mini-map preview of the next pull, enemy portraits, live forces progress bar, and an upcoming-pull preview
- Per-character or account-wide Beacon position (remembered between keys)
- Manual controls to mark pulls complete, skip ahead, or revert
- Click-through panel: blank space never blocks clicks — hold **Alt** to drag or right-click the Beacon
- Per-NPC notes: middle-click a portrait to annotate a mob type, shown on the portrait tooltip and as note strips above the Beacon
- Per-wave notes: middle-click the map to annotate the pull itself — the note rides the strip closest to the Beacon and flags itself if a route edit shifts it onto a different wave
- Auto-start when a Mythic+ key begins, auto-stop when it ends
- One-shot migration of existing Next Pull settings from the parent MDT addon
- Retail (Midnight / 12.0) support

## Slash Commands

- `/npt start` — start tracking the current preset
- `/npt stop` — stop tracking
- `/npt skip <N>` — skip directly to pull N
- `/npt complete` — mark the active/next pull complete
- `/npt status` — print current tracking state and scenario forces
- `/npt info` — full diagnostics (feature flags, preset, scenario criteria)

Right-click the Beacon for per-session toggles (lock, show upcoming, hide, stop tracking).

### Click-through

The Beacon floats over the game world, so its blank space is click-through by default — targeting mobs and click-to-move work straight through it. **Hold Alt** to make the window interactive again: while Alt is down you can drag it and open the right-click menu. Releasing Alt mid-drag drops the Beacon where it is and still saves the position.

The map area is an exception. Its tiles are opaque, so clicking through it would only risk targeting a mob you cannot see — it stays interactive at all times: drag it to move the Beacon, wheel to zoom, middle-click to annotate the current pull.

Portraits, header buttons and cooldown icons likewise keep their own click handling and stay usable whether or not Alt is held.

## Dependencies

- [MythicDungeonTools](https://www.curseforge.com/wow/addons/mythic-dungeon-tools) (required)

## Credits

Built on top of [Mythic Dungeon Tools](https://github.com/Nnoggie/MythicDungeonTools) by Nnoggie.

## Support

If this addon saved you a wipe, a key, or just some stress — consider [buying me a coffee](https://buymeacoffee.com/hypnotix). Every coffee helps keep the addon updated across patches and new seasons.
