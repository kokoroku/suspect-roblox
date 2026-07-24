# "Suspect" — Roblox Dev Roadmap

*Updated to reflect the project's actual state. Supersedes the earlier roadmap, which still described the old Common/Rare/Epic powerup variants, the deleted powerups (Decoy/VisionPulse/VentLock), and "hold E" task placeholders — all long since replaced. For a per-commit record, see `CHANGELOG.md` at the repo root.*

---

## Where the project is right now

The core game is **playable end to end**. A full match runs: round loop → roles assigned → crew do real task minigames while the impostor kills and sabotages → meetings and voting → win condition → end screen → loop. Powerups, the gacha economy, spectating, sabotage, and a styled UI hub are all in.

What's **built and working:**

- **Round loop** — waits for a minimum player count, runs an intermission countdown, plays, shows an end screen, loops. Late joiners spectate and spawn into the next round. (This fixed the published-server bug where the first joiner started a solo match and everyone after was left roleless.)
- **Roles, kills, meetings** — server-authoritative roles, proximity/cooldown kills with ragdoll bodies, body reports and emergency meetings (called from a **physical button at the round table**, not a keybind), voting and ejection, ghost spectate with camera cycling.
- **Powerup economy** — five powerups on two independent axes: **rarity** (fixed, drives gacha odds) and **tier 1–3** (personal upgrade track from duplicates). Gacha rolls which powerup by weight with a pity counter; loadout is a pending/active 2-slot system.
- **Task system** — profile-based short/long assignment that varies per match, server-validated by session + proximity + minimum duration. **All 10 generic minigames are implemented and playtested.**
- **Sabotage** — impostor-triggered Lights and a critical Boiler (countdown that can end the match); fixes reuse the task pipeline.
- **Darkness** — lights-out physically kills the map's lamps for everyone; crew get a small personal glow, impostors see farther; Flashlight extends that vision as a beacon.
- **UI hub** — a shared `UIStyle` module, a bottom bar, and a tabbed Store/Inventory window; Montserrat font, draggable windows, an animated gacha reveal.

**The one dangling verify:** the reworked Flashlight's per-tier fog range hasn't been checked in isolation yet — first task on return.

---

## The five launch powerups (current design)

Rarity and tier are **separate axes** — rarity is fixed per powerup and sets gacha odds + power budget; tier is the personal upgrade track (3 duplicates → +1 tier, max 3). Gacha rolls *which* powerup you get by weight; pity guarantees Rare-or-better within 10 rolls.

| Powerup | Rarity | Roll weight | Effect (scales with tier) |
|---|---|---|---|
| **Speed Boost** | Common | 30 | Temporary movement speed increase |
| **Flashlight** | Common | 30 | During lights-out only: a head glow everyone sees, plus personal vision range reaching impostor parity at T3 |
| **Invisibility** | Rare | 20 | Fully invisible; landing a kill breaks it instantly |
| **Shapeshifter** | Epic | 10 | Copy a nearby player's look + display name (real name untouched, so reports/Seer/corpses stay truthful) |
| **Seer** | Epic | 10 | Privately reveal a nearby player's true role; per-match uses scale with tier |

Class odds work out to Common 60% / Rare 20% / Epic 20%. Seer and Shapeshifter are proximity-targeted (7 studs, same as kill range) — no target picker.

---

## The task pool (complete)

Ten generic minigames, each reused across all three maps with a per-map reskin. Assignment gives each crew member a per-match mix of **short and long** tasks (profiles like 6/1, 5/2, 4/3, never repeating the previous match's split).

**Short:** Wire Splice, Dial Match, Hold & Fill, Slider Sync, Precision Pins, Sort & Stow
**Long:** Echo Code, Scrub Down, Spot Check, Flow Route

Input philosophy is locked: **F** for timing tasks (with on-screen fallbacks), **drag** where physical, **click** where spatial. All world prompts are **E-only** — mouse clicks never start tasks (this fixed a whole class of click-through bugs).

*Parked:* Sort & Stow works but is boring — flagged for a redesign later. Each map also gets 1–2 bespoke **signature tasks**, designed individually, not yet built.

---

## Roadmap (in order)

### ✅ Done
- **Core loop** — roles, kills, ragdolls, meetings, voting, win conditions, full match lifecycle.
- **Powerups + economy** — all 5 effects, rarity+tier model, gacha with pity, pending/active loadout, HUD.
- **Spectate + ghost engagement** — follow-camera, dead-only alive-list broadcast, gacha usable while dead.
- **Round loop** — min-player gate, intermission, late-joiner spectators, mid-match-leave win check.
- **Task framework + all 10 minigames** — the biggest content phase, built and playtested one at a time.
- **Sabotage system** — Lights + critical Boiler, fix stations through the task pipeline, meeting/report gating.
- **Darkness pass** — diegetic lamp-kill, per-role vision asymmetry, crew candle glow, Flashlight rework, fuse-box Lights-Out puzzle.
- **UI hub (QoL, function-final)** — `UIStyle` module, bottom bar, Store/Inventory hub, restyled HUD, Montserrat, animated gacha reveal, draggable windows.
- **CHANGELOG.md** — persistent per-prompt dev record at the repo root.

### 🔜 Next up
1. **Verify the reworked Flashlight tiers** in isolation (the one open check from the last batch).
2. **Full art pass** — re-skin `UIStyle` (the single file the whole UI pulls from) into the final look: rounded cards, rarity colors, the candlelit Estate palette. This is where "functional but rough" becomes "polished." Because everything routes through `UIStyle`, it's largely one-file work plus per-element cleanup. Meeting UI and task-minigame chrome (excluded from the QoL pass) get styled here too.
3. **Sort & Stow redesign** (parked) — fold into the art/polish window whenever it comes up.
4. **Audio pass** — real sound across the game against a shared sound module (kills, meetings, task feedback, sabotage). Only Echo Code has tones today; everything else is intentionally silent.

### 🧱 Bigger systems still to build
5. **Estate detail + vents** — the secret-passage traversal (impostor fast routes) isn't built yet; it's a real mechanic, not just art. Detail-pass the Estate greybox alongside it.
6. **Lobby + DataStore persistence** — replace the attribute-currency stub with a real DataStore-backed currency + owned-collection service (retry/pcall-wrapped). Build the lobby as its own space: matchmaking queue, a gacha/skill-smith area, cosmetic preview/equip, loadout selection. The "Return to Lobby" placeholder and the in-place match restart both become real teleports. Window position/size memory (currently session-only) can persist here too.
7. **Mobile input pass** — every hotkey and world prompt is keyboard/desktop-only right now (a known, deliberate debt). Re-enable touch activation for prompts and add mobile controls for the F-key tasks.
8. **Maps 2 & 3** — the Garage (with its race-track signature room) and Neon District (vertical cyberpunk), built back-to-back once the Estate loop is proven. Each is mostly greybox + reskinned task stations + its vent-equivalent + 1–2 signature tasks. Launch scope is all three maps.

### 🚀 Toward launch
9. **Testing & hardening** — playtests at real counts (5–10) repeatedly; a server-side exploit pass auditing every remote for client abuse.
10. **Soft launch** — small circle first, watch retention ("did they play a second round?"), fix, then push for growth via thumbnail/icon, short-form clips, and a community Discord.

---

## Working conventions (how this project is built)

- **Tightly scoped prompts.** Each Claude Code prompt lists exactly which files change and what changes; nothing else is refactored, renamed, or reformatted. Every prompt ends by summarizing changes per file for review before accepting.
- **Accepted behavior is explicit.** Prompts name the deliberate rough edges ("do NOT fix any of it") so placeholders and known debt aren't silently reworked.
- **Debug flags ship false.** All live in `DebugFlags.lua`; pre-push always greps them (`ALL_IMPOSTORS`, `GRANT_ALL_POWERUPS`, `LIGHTS_TEST_CONTROLS`, `ASSIGN_ALL_TASKS`, sabotage/lights test flags). Some warn loudly when on.
- **Map data lives in the place file, not the repo.** Tagged parts (`TaskStation`, `SabotageStation`, `EmergencyButton`, `RoomLamp`) and attributes (`TaskType`, `SabotageType`, `FixId`) are saved in Studio — keep the place published alongside the code.
- **Cycle-free services.** Cross-service reactions flow through registered hooks (`OnMatchStart`, `OnMeetingStart`, `OnLightsChanged`, `OnAliveChanged`, `OnKillPerformed`, `OnSabotageChanged`) rather than mutual requires; `Bootstrap` wires anything that would otherwise cycle. `Remotes.lua` is the single source of truth for remote names.
- **Assume every client is hostile.** All client→server actions are validated server-side; info a client shouldn't have (others' roles, unreported deaths) is never replicated to it.
- **Commits are tagged** `[major]`/`[fix]` with detailed bodies; the changelog gets a per-prompt entry.

---

## Current accepted placeholders (deliberate — don't "fix" ad hoc)

- Store "Shop" and Inventory "Cosmetics" tabs are inert placeholders for future cosmetics/event items.
- "Return to Lobby" shows a coming-soon toast; matches restart in place until the lobby exists.
- Window position/size resets on rejoin (needs DataStore persistence).
- Ghosts get no candle glow (spectate camera isn't their character).
- Currency is an attribute stub, not persistent.
- Meeting UI and task-minigame windows are functional but unstyled until the art pass.
- Mobile can't start world interactions yet (keyboard/desktop only).
- The Estate is a greybox; secret-passage vents aren't built.

---

## What NOT to build yet

No trading, no power-affecting cosmetics, no extra role variants (sheriff/engineer/etc.) — all post-launch once the core loop is proven and retaining players. Signature tasks are designed one at a time, never batch-generated. Launch is exactly 3 maps and the 10-task pool; everything beyond is a post-launch update.
