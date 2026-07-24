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

### 2026-07-24 - Custom pixel keybind prompts

- Every world ProximityPrompt is switched to `ProximityPromptStyle.Custom` server-side, so the default Roblox prompt UI no longer appears anywhere: task stations, the emergency button, sabotage fix stations and reported bodies.
- Prompt labels corrected at the source: task stations now use the task's themed `TaskDefs` displayName as `ActionText` (with the Generic fallback reading "Use" instead of "Do the Task"), the emergency button reads "Call meeting", body reports read "Report body" (set on every setup, not only when the prompt is created), and sabotage stations keep "Fix". No other prompt config (`ClickablePrompt`, `HoldDuration`, enable/disable logic) changed.
- New client `PromptUI.client.lua` renders the replacement: driven entirely off `ProximityPromptService` (`PromptShown`/`PromptHidden`), it builds one `BillboardGui` per prompt adorned to the interactable - a pixel `PressStart2P` action label with a solid-black outline over a chunky keycap (dark face, near-white 3px stroke, offset drop-shadow, the keyboard key letter in Accent). Hard edges only, no `UICorner`.
- Hold prompts animate a bottom-to-full Accent fill inside the keycap over `HoldDuration` via `PromptButtonHoldBegan`/`Ended`; zero-duration prompts never show a fill. Empty `ActionText` hides the label row and centers the keycap alone.
- Known debt recorded in-file: the keycap always shows the keyboard keycode (desktop-first); the per-platform mobile input pass replaces it later. `PressStart2P` is engine-bundled, with the one font string flagged as the single swap point if it ever fails to resolve.

### 2026-07-24 - Meeting & voting UI restyled against UIStyle

- Presentation-only cleanup of `MeetingUI.client.lua`; every piece of logic, timing and remote handling (`MeetingStarted`/`VoteResult`/`CastVote`, the `hasVoted` guard, the rebuild-each-meeting flow, the result banner persisting for the whole following round) is unchanged. Not the final meeting redesign.
- Added a full-screen dim overlay (black, `BackgroundTransparency 0.45`) behind the meeting panel. The voting frame became a transparent full-screen container so its existing `Visible` toggle shows/hides the overlay and panel together.
- The meeting panel is now a centered `UIStyle.MakePanel` (520 wide) with a `MakeHeader` carrying the same report-vs-emergency title the code already sets; voter rows are `MakeButton`s (player name left, TextPrimary) in a scroller, and Skip is its own `MakeButton` in a holder visually separated below the list.
- The result banner became a centered `MakePanel` with `HeaderFont` text tinted Positive for "No one was ejected." and Negative for an ejection, same display duration and clear-on-next-meeting behavior.
- Montserrat font faces and standard text strokes throughout. No countdown bar was added: the current UI has no timer (`_duration` is received but unused), and no per-target vote-selection styling was added because no such selection state exists in the code - neither feature was invented.

### 2026-07-24 - Meeting countdown bar + vote-selection tint

- Two additions the restyle pass deliberately excluded, now authorized, in `MeetingUI.client.lua` only. Verified first (read-only) that `MeetingSystem` genuinely enforces the window: it sends `MEETING_DURATION` on meeting start and `task.delay(MEETING_DURATION, ResolveMeeting)` auto-resolves on the same value, so the bar visualizes a real timeout and can safely reach zero. `MeetingSystem` was not modified.
- Added a thin 4px countdown bar directly under the panel header: Row-colored track, Accent fill starting full and depleting linearly to zero over the server-sent duration. Heartbeat-driven and token-guarded (a new meeting or the meeting ending invalidates the running loop), shown on meeting start and hidden by the same `VoteResult` flow that ends the meeting display. Purely cosmetic - the client takes no action when the bar empties; the server owns resolution.
- The meeting-start handler now uses its previously underscore-ignored duration parameter to drive the bar. A missing/non-positive duration leaves the bar full rather than counting down to nothing.
- Vote-selection tint: casting a vote (a player row or Skip) now marks that row via `UIStyle.SetButtonSelected(row, true, Accent)`; the single `hasVoted` guard means no other row is ever selected. The tint is cleared when the meeting display ends and the reference is dropped when rows are rebuilt. This mirrors the client-side assumption the `hasVoted` guard already makes (the cast vote is treated as landed); no server vote-confirmation exists and none was invented.

### 2026-07-24 - Kill feedback (impact, mark, sound, cooldown chip)

- New `KillFeedback` server->client remote. On a successful kill `KillSystem` fires it to the killer with the kill cooldown seconds, and adds two pieces of world feedback at the body.
- World mark & sound: a positional `snap.mp3` (engine-bundled, PlaybackSpeed 0.85, Volume 0.6, Inverse rolloff to 35 studs) hosted on the corpse torso/root - audible within ~35 studs by design, kills are information - and a thin dark-red blood-pool Cylinder (~4 studs, 0.1 tall, anchored, no-collide/no-query) raycast onto the floor under the corpse and parented to the corpse model so every existing body-cleanup path removes it automatically. No decals or particles.
- New client `KillFX.client.lua`, layered on top of the existing flow without touching it: the KILLER gets a quick red full-screen vignette (0.55->1 over 0.35s) plus a +4 FOV punch tweened back over 0.25s (no shake); the VICTIM gets a brief red flash (0.4->1 over 0.5s) on their own `PlayerDied` before the existing death/spectate flow; and impostors get a pixel "F" keycap chip (PromptUI-style) to the left of the powerup slots that, on a kill, runs a darkening sweep + countdown over the cooldown then clears.
- The chip is impostor-only via `RoleAssigned`, hidden for crew, and every transient effect is guarded (tween-cancel or a Heartbeat token) and reset on `CharacterAdded`/`MatchEnded`.
- Accepted as-is: no character kill animation (ragdoll is the animation), the snap sound is a placeholder for the audio pass, and the chip only shows a countdown after the first kill (no match-start readiness signal yet).

### 2026-07-24 - Settings system core (module + window)

- New `ClientSettings.lua` ModuleScript: the single source of truth for client settings, session-only by design (DataStore persistence is a later phase, noted in the header). Holds keybind defaults + display names for nine remappable actions (Kill/Store/Inventory/Sabotage/Powerup1/Powerup2/SpectatePrev/SpectateNext/TaskAction), a `RESERVED` set (W/A/S/D/Space/E - movement plus the shared server-side prompt interact key), and the API: `GetKey`/`SetKey` (rejects `Reserved` and `InUse`, duplicate detection across remappable actions only), `GetVolume`/`SetVolume`, `GetReduceEffects`/`SetReduceEffects`, `ApplyVolume(base)`, a `Changed` BindableEvent fired with the setting name, and a `ResetLayout` BindableEvent with `FireResetLayout()`.
- New `SettingsUI.client.lua`: a bottom-left cog button (UIStyle square, emoji with a documented "Set" text fallback) toggles a fixed-size (380x460) draggable `MakePanel` window with a `MakeHeader` "Settings" + X, opened centered-left and force-hidden on meeting start like the hub.
- Window sections: Audio (a delta-drag master-volume slider with Accent handle/fill and a percent label, reading/writing `ClientSettings` volume); Keybinds (one row per action in a scroller with a PromptUI-style pixel keycap chip, a click-to-capture remap flow - "Press a key...", Escape cancels, Reserved/InUse flash a red notice and keep the old binding, one capture at a time - plus a fixed dimmed "Interact (world) [E]" row and a reserved-key note); Interface (a "Reset UI layout" button calling `FireResetLayout`); Accessibility (a "Reduce screen effects" ON/OFF toggle, Positive tint when on).
- Rows repaint live from `ClientSettings.Changed`. Nothing consumes these values yet - the next prompt migrates every consumer; the cog is text/emoji until the art pass.

### 2026-07-24 - Settings wired into every consumer

- Every hardcoded keybind now resolves through `ClientSettings.GetKey(...)` compared at input time inside the existing `InputBegan`/`InputEnded` handlers (never cached at startup), so remaps apply instantly with no reconnection; every existing `gameProcessed` guard is preserved. Migrated: `KillInput` (Kill), `HubUI` (Store/Inventory), `SabotagePanel` (Sabotage), `PowerupHUD` (Powerup1/2), `SpectateUI` (SpectatePrev/Next), and the `DialMatch`/`HoldFill`/`PrecisionPins` task hotkeys (TaskAction). The now-dead `KILL_KEY`/`PREV_KEY`/`NEXT_KEY`/`TOGGLE_KEY` constants were removed.
- On-screen key labels re-read the current binding: PowerupHUD slot badges (One->"1", Two->"2", letters as-is), the SpectateUI legend ("G - Store   L - Inventory"), BottomBar buttons ("Store [G]" / "Inventory [L]"), the KillFX cooldown chip keycap, and the `DialMatch`/`HoldFill` "HOLD [F]" buttons - all refresh on `ClientSettings.Changed` (task buttons render at Build time).
- Client-created sounds pass their final Volume through `ClientSettings.ApplyVolume(base)`: EchoCode's `playNote` and HubUI's gacha tick/landing/Epic notes. Each site notes that the master slider governs client sounds while world/positional sounds join via SoundGroups in the audio pass.
- Accessibility: KillFX skips the killer vignette and FOV punch entirely when `GetReduceEffects()` is true; the victim flash still plays (it communicates death, not flair) and the cooldown chip is informational, both commented.
- Layout reset: TaskListUI (position + size) and SabotagePanel (position) subscribe to `ClientSettings.ResetLayout` and restore their captured defaults, clearing their session-remembered values.
- Unchanged by design: PromptUI's world keycap still shows the prompt's own fixed E; the kill snap and server-side sounds ignore the slider until the audio pass; settings remain session-only.

### 2026-07-24 - Settings window playtest fixes

- Layout: the settings window is now a fixed 400x560 (was 380x460), opens centered-left, drags by its header, and has no resize of any kind. Everything below the header is now ONE `ScrollingFrame` (UIListLayout with 8px padding, `AutomaticCanvasSize` Y, `ScrollBarThickness` 4, 12px right padding so nothing sits under the scrollbar). The nested keybinds scroller was deleted - keybind rows flow directly in the main list between section labels, so every section (including the Reduce screen effects row) is fully reachable and never half-cut.
- Fonts: audited every text instance - all labels, headers, buttons, notices and hints use `UIStyle` Montserrat faces with the standard stroke; the pixel `PressStart2P` font now appears in exactly one place, the key text inside keycap chips.
- Keycap chips: each is a full square Frame (min 30x30, no `UICorner`, a complete four-sided 2px near-white `UIStroke`, dark fill), right-aligned with clearance from the scroll edge so the border is never clipped. Displayed key uses the same short-name mapping as the HUD badges (One-Nine -> "1".."9", Zero -> "0", single letters as-is, else `KeyCode.Name`), and the chip auto-widens up to ~64px for longer names instead of crushing the text. The fixed "Interact (world)" row keeps its dimmed styling with the same full-square chip.
- Capture feedback: clicking a chip switches its stroke to Accent and pulses it (transparency tweened 0<->0.6 on a loop, token-guarded), replaces the key text with a keyboard glyph, and adds a "(press a key)" suffix to the row label. Success stops the pulse and flashes the chip Positive before showing the new key; Reserved/InUse flash Negative alongside the row notice and keep the old key; Escape cancels cleanly. Starting a capture on a second chip cancels the first.

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
