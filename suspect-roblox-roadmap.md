# "Suspect" — Roblox Dev Roadmap (Idea → Playable Game)

## Name check
"Suspect" is solid — short, readable, on-theme, easy to search. A couple of backups in case it's taken or you want more flavor: **Suspicion**, **Sus HQ**, **The Setup**, **Codename: Sus**. I'd stick with Suspect unless the Roblox name is unavailable.

---

## 1. Tools (kept deliberately minimal)

| Tool | Purpose | Cost |
|---|---|---|
| **Roblox Studio** | The engine. Non-negotiable. | Free |
| **VS Code + Rojo** | Real editor + Claude Code assistance, synced into Studio. Real version control instead of Studio's fragile built-in history. | Free |
| **GitHub** | Version control + backup. | Free |
| **Claude (chat + Claude Code in VS Code)** | Writing/debugging Luau, RemoteEvent architecture, gacha math, UI logic, level layout. | Already have it |
| **Building Tools by F3X** (Studio plugin) | Fast building/resizing/rotating — the community-standard alternative to Studio's stock handles. | Free |
| **Photopea or Figma** | UI mockups, icons, thumbnail, gacha item cards. | Free |
| **Roblox Toolbox (built into Studio)** | Free community models/meshes for placeholder props. | Free |

Skip Blender for now — custom 3D modeling isn't needed to hit "playable game fast." Bring it in later once the core loop is proven fun and you want a signature look.

---

## 2. Core game loop (everything else serves this)

```
LOBBY (matchmaking + gacha/cosmetics browsing, ~30-60s wait)
   ↓
LOADOUT: equip 2 powerup slots from your owned collection
   ↓
MATCH START (crew vs impostor(s) assigned)
   ↓
ROUND: crew does task minigames, impostor(s) sabotage/eliminate,
        both sides using their 2 equipped powerups when useful
   ↓                                  ↓ (if you die)
MEETINGS: report body / emergency    GHOST: spectate the living,
   → discuss → vote                   roll gacha while you wait,
   ↓                                  exit to lobby if you'd rather
WIN CONDITION: tasks complete / impostors ejected / crew eliminated
   ↓
END SCREEN (timed) → currency payout based on performance
   ↓
BACK TO LOBBY → spend currency on gacha pulls → new loadout combos →
   show off skins/effects → friends notice → invite friends → loop repeats
```

Death is no longer a dead end: ghosts spectate and can spend their session currency in the gacha immediately, which keeps eliminated players engaged instead of alt-tabbing out — that's a retention lever, not just a QoL feature.

Two reward tracks feed this loop:
- **Cosmetics** = pure gacha, no gameplay effect — skins, death effects, name tags, lobby emotes. Purely a flex/collection loop.
- **Powerups** = rollable via gacha as **rarity variants of the same ability** (e.g. Speed Boost: Common/Rare/Epic) — rarity changes *degree* (duration/strength), never *access*. Players **equip exactly 2 powerups from their owned collection before each match**, chosen in the lobby. This makes powerups a genuine loadout/build decision, giving the game a real skill ceiling on top of the collection loop. Roll currency is earned through play by default (Robux top-up optional, never required), odds are always shown before rolling, and a pity counter guarantees a Rare+ within a set number of rolls.

This is also why the game stays fun to watch and stream — loadout choices are visible and debatable, nobody's flatly locked out of an ability, and nobody's mad about losing to someone's wallet alone.

---

## 3. The three launch maps

**The game ships with 3 maps at initial release** (this is a scope change from the earlier draft, which deferred maps 2–3 to post-launch). Sequencing stays disciplined: Map 1 is built and *proven fun* first; maps 2 and 3 are then meaningfully cheaper because the reusable task pool (Section 4) already exists — each new map is mostly a greybox, reskinned task stations, its vent-equivalent, and 1–2 signature tasks.

### Map 1 — The Estate (Victorian manor)
The tone-setter: a candlelit Victorian mansion, which fits "Suspect" far better 
than a sci-fi default and immediately distances the game from reading as an Among Us reskin.

- **Layout:** central Grand Hall (spawn + meetings) connected by hallways to Library, Kitchen, Study, Dining Room, Conservatory, Cellar.
- **Vent-equivalent:** secret passages (Library↔Cellar, Study↔Conservatory) — impostor-only fast routes dressed as the manor's hidden architecture.
- **Palette/feel:** warm candlelight, dark wood, deep reds and brass; low-poly with strong flat color-coding per room.
- Greybox already generated and in Studio.

### Map 2 — the mechanic shop (working name: **The Garage** / *Redline Garage* / *The Pit Stop*)
A cluttered auto shop with personality — and its centerpiece: **a room containing a small race track**, the map's signature set piece and a natural home for one of its bespoke signature tasks.
- **Layout sketch:** service bays with lifts (spawn + meetings in the main bay), parts storage, tool room, front office, tire wall, paint booth, and the race track room.
- **Vent-equivalent:** under-floor creeper tunnels / service pits connecting the bays — staying on-theme as the mechanic's crawlspaces.
- **Palette/feel:** grease-stained grays and steel blues punched up with racing-livery accents (checkered flags, one loud accent color).

### Map 3 — the futuristic city (working name: **Neon District** / *The Sprawl* / *Night Circuit*)
A compact cyberpunk city block, Cyberpunk 2077-inspired: dense, vertical, neon-soaked.
- **Layout sketch:** central plaza (spawn + meetings) ringed by a noodle bar, arcade, tech shop, back alleys, a rooftop level, and maintenance corridors.
- **Vent-equivalent:** maintenance ducts and a grav-chute or two linking street level to rooftops — verticality is this map's identity.
- **Palette/feel:** near-black base with saturated neon signage (magenta/cyan/amber); rain-slick reflective floors if performance allows, flat-shaded if not.

Working names above are suggestions — final names to be picked before each map's art pass.

---

## 4. Task system (the big rehaul)

All current task stations are placeholders ("walk up, hold E"). The rehaul replaces them with a **reusable minigame framework**: triggering a station opens a 2D GUI minigame on the client; the client plays it and reports completion; the server validates everything it can (assignment, not-already-done, proximity to that station, match in progress, no meeting active, minimum-elapsed-time so a hacked client can't instant-complete). One shared task-definitions module maps stations to task types — built map-agnostic from day one so new maps are content, not code.

### The 10-task generic pool (ships at launch, shared across all 3 maps)
Ten mechanics, each with a per-map skin — same logic, different name/props/sound. Interaction verbs are deliberately varied so 3 assigned tasks rarely feel samey. More generic tasks join the pool in post-launch updates alongside new maps.

| # | Mechanic | How it plays | Estate | Garage | City |
|---|---|---|---|---|---|
| 1 | **Wire Splice** | Drag 4 colored plugs to matching sockets | Rewire the Chandelier | Splice the Battery Leads | Patch the Neon Sign |
| 2 | **Dial Match** | Rotate a needle into a target arc, hold steady; 3 locks | Tune the Gramophone | Adjust the Carburetor | Align the Antenna Array |
| 3 | **Echo Code** | Watch a flashing sequence, repeat it (3→4→5 long) | Play Back the Piano Refrain | Enter the Garage Keypad | Crack the Door Cipher |
| 4 | **Hold & Fill** | Hold while a gauge climbs, release in the band; overshoot drains | Fill the Oil Lamps | Fill the Fuel Tank | Charge the Power Cell |
| 5 | **Sort & Stow** | Drag 6 items into 3 correct bins | Shelve the Library Books | Sort the Fasteners | File the Data Chips |
| 6 | **Slider Sync** | Set 3 sliders onto their faint target lines | Trim the Gas Lamps | Balance the Wheel Weights | Stabilize the Hologram |
| 7 | **Scrub Down** | Wipe grime off a panel until ~90% clean | Polish the Silverware | Degrease the Engine Block | Clean the Terminal Screen |
| 8 | **Precision Pins** | Click a sweeping marker in the sweet spot ×3 | Pick the Cabinet Lock | Crack the Tool Chest | Spoof the Access Panel |
| 9 | **Spot Check** | Find and click 4 listed items in a cluttered scene | Find the Master's Keys | Recover the Dropped Screws | Locate the Data Shards |
| 10 | **Flow Route** | Rotate pipe tiles to connect source → drain | Mend the Boiler Pipes | Route the Air Line | Reconnect the Coolant Loop |

### Signature tasks
Each map also gets **1–2 fully bespoke signature tasks** — this is where the uniqueness budget goes (the Garage's race track room is an obvious candidate host). These are designed individually, one at a time, and are deliberately NOT built yet.

Replayability lever: build more stations than needed per map and randomize which subset is active each round.

---

## 5. Roadmap (in order)

### Phase 0 — Setup & scope lock ✅ *done*

### Phase 1 — Core loop prototype ✅ *done*
Roles (server-authoritative, Fisher-Yates), KillSystem (R6 ragdoll with constraint joints + collision groups), MeetingSystem (report/emergency, Among Us-style voting where Skip competes in the tally and any top tie ejects no one), win conditions, and the full **match lifecycle**: MatchService owning start → win evaluation on every trigger (kills, ejections, task completion) → timed end screen → auto-restart in place (placeholder for lobby teleport). One consolidated debug flag file (DebugFlags.lua) — all flags false to ship.

### Phase 1.5 — Map 1 greybox + task stations 🔨 *in progress*
Estate greybox is built and in Studio with tagged placeholder stations. Real detail pass waits for the art phase.

### Phase 2 — Powerups + loadout ✅ *done (1 of 4 effects implemented)*
PowerupService, PowerupOwnershipService, LoadoutService built and tested. Decoy/VisionPulse/VentLock effect handlers still to write (Phase 7).

### Phase 3 — Currency + gacha ✅ *mostly done*
GachaService with disclosed odds + pity, single source of truth for odds shown vs. odds used. Still pending: swap the attribute currency stub for DataStore persistence (Phase 8).

### Phase 4 — Spectate + dead-player engagement 🔨 *current*
Follow-camera spectate with target cycling for ghosts (alive-list broadcast **to dead players only** — living clients never learn about unreported deaths), gacha panel usable while dead, Return to Lobby button (placeholder until the lobby exists).

### Phase 5 — Task framework + the 10-task pool
Build the minigame framework (Section 4), prove it with one placeholder minigame, then implement the 10 generic tasks one at a time. Per-map signature tasks are designed individually and slot in as each map firms up.

### Phase 6 — UI rehaul (one full pass)
Start with a tiny shared style module — palette, fonts, corner radius, rarity colors — that every UI script pulls from, so future restyles are one-file edits. Then restyle everything against it: task list, minigame chrome, meeting/voting, end screen, spectate bar + gacha panel, and the impostor HUD that doesn't exist yet (visible kill button with cooldown, powerup slot buttons). Doing this *after* the task framework means styling a complete set of surfaces once, instead of twice.

### Phase 7 — Round-feel
Estate's secret passages working in-game; the 3 remaining powerup effects; minimum-player gate on match start; ghost QoL as needed.

### Phase 8 — Lobby + persistence
Real DataStore-backed CurrencyService (retry/pcall-wrapped) replacing the stub; the lobby as its own space: matchmaking queue, gacha machine reading GetDisclosure/GetCatalog, cosmetic preview/equip, loadout selection, leaderboard — and the Return to Lobby button becomes a real teleport.

### Phase 9 — Maps 2 & 3
Built back-to-back once Map 1's loop is proven: greybox, reskinned task pool, vent-equivalents, signature tasks. Launch scope is all three.

### Phase 10 — Testing & hardening → Launch
Playtests at real player counts (5–10) repeatedly. Server-side exploit pass: audit every Remote for "could a modified client abuse this." Then soft launch to a small circle, watch retention, fix, push for growth.

**Post-launch cadence:** new generic tasks into the shared pool + new maps, together, as updates.

---

## 6. Luau architecture notes

- **ModuleScripts** for all game logic — testable, and lets Claude edit one system without touching others.
- **Remotes.lua is the single source of truth** for every RemoteEvent *and* RemoteFunction name; server creates them all on boot.
- **Hook pattern for cross-service reactions** without circular requires: MeetingSystem.OnMeetingStart, MatchService.OnMatchStart, TaskManager.OnTaskCompleted, RoleManager.OnAliveChanged. Dependencies stay one-directional; new cross-cutting behavior should register a callback, not add a require cycle.
- **Assume every client is hostile.** All client→server actions validated server-side; information the client shouldn't have (roles of others, unreported deaths) is never replicated to it.
- **DataStoreService** (retry/pcall-wrapped) for currency + owned collection — Phase 8.

### Current accepted placeholders (known, deliberate, don't "fix" ad hoc)
- Return to Lobby button shows a "coming soon" toast until the lobby exists.
- No loadout UI until the lobby phase (TestClient was deleted), so powerups are unequippable in the interim.
- Meeting/task-list/end-screen/spectate UI are functional-but-ugly until Phase 6.
- Late joiners mid-match spawn roleless and wait for the next round.
- Ejected players' corpses persist until the next match starts.
- Matches restart in place after the end screen — replaced by lobby flow in Phase 8.

---

## 7. Look & feel

**Low-poly, flat-shaded, saturated colors**, applied per-map:
- Characters: default Roblox avatars (R6, forced via Game Settings) with custom accessories/skins from the gacha.
- Maps: simple geometric rooms, strong flat color-coding per room, Toolbox props re-colored to each map's palette (Estate: candlelit warm/dark wood; Garage: workshop grays + racing accents; Neon District: dark base + saturated neon).
- UI: rounded cards, bold color-coded rarity tiers (gray/blue/purple/gold) for gacha items, driven by the shared style module.

---

## 8. Getting to 1,000 concurrent players

Roblox auto-scales servers, so CCU isn't a technical ceiling — it's an acquisition + retention problem:
- **Retention first, always.** Watch "did they play a 2nd round" above all else. (The ghost gacha loop exists partly for this.)
- **Icon + thumbnail** matter disproportionately on Roblox's discovery feed.
- **Short-form clips** (TikTok/YouTube Shorts) are the highest-leverage low-cost growth channel.
- **Roblox Ads** once retention is proven, not before.
- A small **Discord** for the playerbase drives repeat sessions and word-of-mouth.

---

## Summary of what NOT to build yet
No trading, no cosmetic-affecting-power items, no complex role variants (sheriff/engineer/etc.) — all v2+ once the core loop is proven fun and retaining players. Signature tasks are designed one at a time with intent, never batch-generated. Launch is exactly 3 maps and the 10-task pool; everything beyond that is a post-launch update.