# Suspect - Changelog

Maintained per-prompt as a durable development record; entries are appended chronologically so the file survives context loss.

## Project overview

Suspect is a Roblox social-deduction game (crewmates vs. impostors) built as a Rojo project. What exists in the code today:

- **Round loop** - `MatchService` waits for a minimum player count, runs an intermission countdown, plays the match, shows an end screen, and loops. Late joiners spectate and spawn into the next round.
- **Roles, kills, meetings** - `RoleManager` is the single source of truth for role and alive-state; `KillSystem` does proximity/cooldown-validated kills with ragdoll bodies; `MeetingSystem` runs body reports and emergency meetings, seats players at a table, tallies votes and ejects. Dead players get a spectate camera with target cycling.
- **Powerup economy** - five powerups (SpeedBoost, Flashlight, Invisibility, Shapeshifter, Seer) across two independent axes: rarity (fixed, drives gacha odds) and tier 1-3 (personal upgrade track). `GachaService` rolls which powerup you get by weight with a pity counter; duplicates bank toward tier upgrades; `LoadoutService` stages a pending 2-slot loadout that only becomes active at match start.
- **Task system** - `TaskManager` assigns a per-match profile of short/long tasks from stations tagged in the place file, validated server-side by session, proximity and minimum duration. Ten minigames are implemented (WireSplice, DialMatch, HoldFill, SliderSync, PrecisionPins, SortStow, EchoCode, ScrubDown, SpotCheck, FlowRoute) plus a Placeholder fallback.
- **Sabotage** - `SabotageService` owns impostor-triggered sabotages (Lights, and a critical Boiler on a countdown that can end the match), cooldowns, and fix sessions routed through the same client task pipeline (FixSwitches, FixValve).
- **UI** - a shared `UIStyle` module backs a persistent bottom bar, a tabbed hub window (Store/Inventory), the task list, powerup HUD, round-status and sabotage banners, meeting UI, end screen and spectate bar.

## History

### 2026-07-15 - Project scaffold and first services
- Initial commit: Rojo project scaffold plus the core server services.
- `TaskManager` and the tagged task-station handler added and wired into `Bootstrap`.

### 2026-07-16 to 2026-07-20 - Kills, meetings, ragdolls, test map
- Split powerup ownership from the equipped loadout into a 2-slot system; added the missing `SetLoadout`/`LoadoutResult` remote names.
- `KillSystem`: proximity- and cooldown-validated kills with a ragdoll on death.
- `MeetingSystem`: body reports, emergency meetings, voting UI and ejection (shipped untested).
- Debug mode to make all players impostors (and let impostors kill each other) for small-group testing.
- Several ragdoll iterations, ending on the `BreakJoints` approach with collision so bodies can be pushed, and a fix for flailing by zeroing Humanoid health after joints are replaced with constraints.
- Round-end cleanup: result banner persists per round, bodies cleared at round end.
- Added the test map "The Estate" to the place file, with a note that the UI needed a full redo before tasks were fleshed out.

### 2026-07-22 - `[major]` Core gameplay fixes + crew task list UI
- Task stations no longer disabled globally after one player completed them (this had been silently blocking the crew task win condition).
- Tasks assigned only to crew, after roles are decided; match start became a one-shot gate with a join grace period so roles/tasks stopped resetting on every join.
- New `TasksUpdated` remote and `TaskListUI` showing each crew member their own tasks with live done/total progress.
- Meeting safety: kills and powerup use blocked during meetings, votes validated against the meeting's alive snapshot, active speed boosts canceled at meeting start via the new `OnMeetingStart` hook.

### 2026-07-22 - `[major]` Match end flow, end screen, spectate + ghost gacha
- New `MatchService`: win condition evaluated on kills, meeting resolutions **and** task completion (which previously could never end a match), with parity excluded from task-triggered checks so finishing a task can't hand impostors a win.
- `MatchEnded` broadcast, a token-guarded `EndScreenUI`, and an in-place restart standing in for the future lobby teleport; the `OnMatchStart` hook lets services reset their own state.
- New `SpectateService`: dead players follow the living with Q/E cycling. The alive list is broadcast to dead players only, so living clients can't detect unreported kills.
- Gacha usable while dead, plus a new `GetGachaCatalog` RemoteFunction; `GrantOrUpgrade` now returns New/Upgraded/Duplicate instead of a boolean, fixing every roll being mislabeled a duplicate.
- All-impostor debug consolidated into a single `DebugFlags` flag with a loud server-start warning.

### 2026-07-22 - `[major]` Powerup rework (shipped untested, verified later)
- Replaced the Common/Rare/Epic *variant* system: rarity became a fixed property driving gacha odds, and tiers 1-3 became the personal upgrade track - two separate axes.
- Ownership is tier + duplicates; rolling never auto-upgrades. Three duplicates buy one tier, max Tier 3, via a server-side `TryUpgrade`.
- Gacha rolls which powerup by weight (Common 60% / Rare 20% / Epic 20%); pity guarantees Rare-or-better within 10 rolls.
- Deleted Decoy, VisionPulse and VentLock; shipped the five launch powerups with per-tier stats.
- Loadout system with pending vs. active sets, so a save stages the next match and the active set is locked for the current one.
- Generic active-effect registry with identity-token timers; new `OnKillPerformed` and `OnLightsChanged` hooks; a minimal `LightsSystem` stub so Flashlight was testable.
- Rough UI added: `PowerupHUD`, `LoadoutUI`, reworked gacha panel, and `PowerupFX` as the single owner of client-side Lighting.

### 2026-07-23 - `[major]` Round loop, task framework, first minigame
- Replaced the one-shot match-start gate with a real round loop, fixing the published-game bug where the first joiner started a solo match and later arrivals were left roleless.
- Late joiners became full spectators with gacha and loadout access; new `RoundStatus` remote and banner; leaving mid-match triggers a win check; empty-server wedge guard.
- Task framework: stations open a real task window, with server-tracked sessions validated by proximity and minimum duration. Assignment became profile-based (7 tasks split short/long, never repeating the previous match's split), backed by a new shared `TaskDefs` module.
- **Wire Splice**, the first real minigame, on the contract every later minigame follows.
- Emergency meetings moved from a global M keybind to a physical tagged button at the round table.
- Confirmed the previous commit's powerup rework as playtested end to end.

### 2026-07-23 - `[major]` Echo Code + task testing flag
- **Echo Code**, the first long minigame: a Simon-style flashing sequence over three extending rounds, with infinite retries so the cost of failure is time.
- Audio deliberately scoped to this one task, pitched from a single engine-bundled `rbxasset` sound so there's no marketplace or moderation dependency.
- New `ASSIGN_ALL_TASKS` debug flag giving every crew player every registered task, replacing manual profile-table edits.

### 2026-07-24 - `[major]` MILESTONE: full 10-task minigame pool + E-only world prompts
- All ten generic minigames playable, completing the task pool phase: the five remaining shorts (Dial Match, Hold and Fill, Precision Pins, Slider Sync, Sort and Stow) and three longs (Scrub Down, Spot Check, Flow Route, the last generated backwards from a carved solution so it's solvable by construction).
- Input philosophy locked in: F for timing tasks with on-screen fallbacks, drag where physical, click where spatial.
- Solved the "tasks reset on click" mystery: ProximityPrompts are mouse-clickable by default and GUI frames pass clicks through, so clicking inside a task window re-triggered the station behind it. All world prompts are now E-only, task windows sink clicks, and a new `TaskCancel` remote clears sessions so stations can't wedge.
- Known mobile debt recorded: touch devices activate prompts by tapping, so mobile can't start world interactions until a per-platform input pass.

### 2026-07-24 - Window drag smoothness + powerup badge readability
- `UIStyle.MakeDraggable` rewritten to move by the delta from the grab point added to the panel's position at the grab, rather than re-deriving position from the absolute pointer each frame - the window now tracks the cursor 1:1 instead of snapping on the first frame of a drag.
- Grab state renamed to `dragStartPointer`/`dragStartPos` and captured on press; the 40px on-screen clamp still applies to the final position, and the resize/drag mutual-exclusion guard (no drag starts within `EDGE` px of a border or while a resize is active) is unchanged.
- Powerup HUD keybind badges enlarged from 16x14 to a 20x20 key cap: dark `Bg` chip with a 1px Accent stroke, 3px padding, rounded corner, and the digit in bold Accent `TextScaled` so it is centered and no longer smashed into the slot corner. The slot's name label, cooldown overlay, countdown, status line and Seer toast are untouched.

### 2026-07-24 - Hub window locked to a fixed size
- Removed `MakeResizable` from the hub window entirely; the resize input layer was interfering with it and shifting it around. No resize grip, handle or bounds references remain in `HubUI`.
- The hub is now a fixed `540x480`, anchor `(0.5, 0.5)`, position `UDim2.new(0.5, 0, 0.5, 0)`, stored as two constants and applied on open. The session position/size memory (the saved geometry and its two `GetPropertyChangedSignal` listeners) is gone, so nothing re-applies a remembered size.
- Tab switching touches only the content frame: `openTab` clears and rebuilds the inner content and re-tints the tab buttons, and never reads or writes the window's Position or Size.
- The header stays draggable - `MakeDraggable` only moves the panel from an `InputBegan` on the header strip followed by pointer movement, so opening the hub or switching tabs cannot move it.
- `UIStyle.MakeResizable` is unchanged and still in use by the task list, which keeps its edge/corner resizing.

## Conventions

- **Tightly scoped prompts.** Each prompt lists exactly which files change and what changes in them; nothing else is refactored, renamed or reformatted, and files outside the list aren't touched.
- **Accepted behavior is explicit.** Prompts name the rough edges that are deliberate ("do NOT fix any of it") so placeholders and known debt don't get silently reworked.
- **Debug flags ship false.** Every toggle lives in `DebugFlags.lua`, nowhere else, and must be false to ship; some print a loud warning when enabled.
- **Map data lives in the place file.** Tagged parts, `TaskType`/`SabotageType`/`FixId` attributes and the test map are saved in Studio, not in this repo - keep the place published alongside the code.
- **Cycle-free services.** Cross-service reactions flow through registered hooks (`OnMatchStart`, `OnMeetingStart`, `OnLightsChanged`, `OnAliveChanged`, `OnSabotageChanged`) rather than mutual requires; the composition root (`Bootstrap`) wires anything that would otherwise cycle.
- **Commits are tagged.** `[major]` for feature arcs (with detailed multi-paragraph bodies), `[fix]` for corrections; commit bodies carry the reasoning and a "next up" list.
- **Placeholders are labeled.** Stubs say what replaces them and when.

## Unreleased / in progress

The working tree has substantial uncommitted work on top of `0a8ec82` (the last `[major]`), spanning several prompts:

- **Sabotage system** - new `SabotageService` (triggers, shared cooldown, the critical Boiler countdown that force-ends the match, fix sessions) and `SabotageStationHandler`; `RoleAssigned`/`SabotageStatus`/`TriggerSabotage` remotes; `MatchService.ForceEnd`; emergency-button and body-report gates; client `SabotagePanel` (C) and `SabotageBanner`; `FixSwitches` (Lights Out puzzle) and `FixValve` fix minigames, both click-only because impostors may legally open them and F is the kill key.
- **Darkness pass** - `LightsSystem` now kills tagged `RoomLamp` parts server-side so the world visibly darkens for everyone, while `PowerupFX` owns the per-role fog/ambient asymmetry, a personal crew "candle" light, and a reworked Flashlight (a head glow everyone can see, paired with a tier-scaled fog range).
- **UI hub era** - new shared `UIStyle` module (colors, Montserrat font faces, text strokes, builders, drag/resize helpers), a persistent `BottomBar`, and a tabbed `HubUI` (Store/Inventory) that absorbed and replaced the standalone loadout and gacha panels; every remaining HUD element restyled against `UIStyle`.
- **Gacha reveal** - a client-side decelerating spin/landing animation over the unchanged instant server roll, with rarity-colored results, a pop/pulse landing, an Epic flourish, and skip-to-landing.
- **Window behavior** - draggable, edge/corner-resizable windows with hover cursors and edge highlights, replacing an earlier handle-frame approach whose invisible hit regions caused stray resizes.

Not yet playtested as a whole, and the roadmap file still describes the older powerup and task designs.
