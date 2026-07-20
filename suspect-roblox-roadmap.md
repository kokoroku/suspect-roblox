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
| **Claude (this chat, or Claude Code in VS Code)** | Writing/debugging Luau, RemoteEvent architecture, gacha math, UI logic, level layout. | You already have it |
| **Building Tools by F3X** (Studio plugin) | Fast building/resizing/rotating — the community-standard alternative to Studio's stock handles. | Free |
| **Photopea or Figma** | UI mockups, icons, thumbnail, gacha item cards. | Free |
| **Roblox Toolbox (built into Studio)** | Free community models/meshes for placeholder props. | Free |

Skip Blender for now — you don't need custom 3D modeling to hit "playable game fast." Bring it in later once the core loop is proven fun and you want a signature look.

---

## 2. Core game loop (design this first — everything else serves it)

```
LOBBY (matchmaking + gacha/cosmetics browsing, ~30-60s wait)
   ↓
LOADOUT: equip 2 powerup slots from your owned collection
   ↓
MATCH START (crew vs impostor(s) assigned)
   ↓
ROUND: crew does tasks, using their 2 equipped powerups when useful
        impostor(s) sabotage/eliminate, using their 2 equipped powerups
   ↓
MEETINGS: report body or call meeting → discuss → vote
   ↓
WIN CONDITION: tasks complete / impostors ejected / crew eliminated
   ↓
END SCREEN: currency payout based on performance
   ↓
BACK TO LOBBY → spend currency on gacha pulls (new powerups/variants + cosmetics) →
   try new loadout combos → show off skin/effect → friends notice → invite friends → loop repeats
```

Two reward tracks feed this loop:
- **Cosmetics** = pure gacha, no gameplay effect — skins, death effects, name tags, lobby emotes. Purely a flex/collection loop.
- **Powerups** = rollable via gacha as **rarity variants of the same ability** (e.g. Speed Boost: Common/Rare/Epic) — rarity changes *degree* (duration/strength), never *access*. Players **equip exactly 2 powerups from their owned collection before each match**, chosen in the lobby. This turns powerups into a genuine loadout/build decision instead of a random pickup, giving the game a real skill ceiling on top of the collection loop. Roll currency is earned through play by default (Robux top-up optional, never required), odds are always shown before rolling, and a pity counter guarantees a Rare+ within a set number of rolls.

This is also why the game stays fun to watch and stream — loadout choices are visible and debatable, nobody's flatly locked out of an ability, and nobody's mad about losing to someone's wallet alone.

---

## 3. Roadmap (in order)

### Phase 0 — Setup & scope lock ✅ *done*

### Phase 1 — Core loop prototype ✅ *done*
RoleManager, KillSystem (R6 ragdoll, working), MeetingSystem (report/emergency/voting), and the win condition checker are all built and tested server-authoritative.

### Phase 1.5 — Real test map + task design 
Two things, done together, since testing tasks properly needs somewhere real to test them:

**Build a greybox map first.** Plain colored blocks at real scale before any real detail — this is standard professional level-design practice, not a shortcut. Your task architecture (tagged parts + ProximityPrompt) means a greybox room is already functionally complete and testable with zero real art.

**Design tasks as one reusable system, reskinned per map:**
- Build a small set of core, reusable task mechanics (4-6): calibration/dial-match, wiring/connect-the-dots, memory sequence, timed hold-and-fill, sort/deliver.
- Reskin these per map — same ModuleScript logic, different props/name/sound. A calibration task becomes "recalibrate the reactor" or "tune the radio" depending on theme.
- Each map also gets 1-2 fully bespoke "signature" tasks — this is where the real uniqueness budget goes.
- Vents follow the same rule: keep the mechanic (fast impostor-only shortcut), reskin the dressing per theme (secret passages, staff corridors, maintenance hatches).
- Build more task stations than needed per map and randomize which subset is active each round — that's your replayability lever without needing new maps.

**Map 1, "The Estate"** (mansion theme — fits "Suspect" far better than a sci-fi default, and immediately distances the game from reading as an Among Us reskin): a central Grand Hall (spawn + meetings) connected by hallways to Library, Kitchen, Study, and Dining Room, with two secret passages (Library↔Cellar, Study↔Conservatory) as this map's vent-equivalent. A full greybox generator script for this exact layout is ready to import — see the message below this roadmap.

### Phase 2 — Powerups + loadout ✅ *done*
PowerupService, PowerupOwnershipService, LoadoutService all built and tested.

### Phase 3 — Currency + gacha ✅ *mostly done*
GachaService built with disclosed odds + pity system. Still pending: swap the stub currency (`player:SetAttribute`) for real DataStore-backed persistence.

### Phase 4 — Lobby, UI, art pass
Build the lobby as its own space: matchmaking queue, gacha machine, cosmetic preview/equip, loadout selection, leaderboard. Apply your art style consistently across map, characters, and UI (see Section 5).

### Phase 5 — Testing & hardening
Playtest with friends at real player counts (5-10 people) repeatedly. Server-side exploit pass: audit every RemoteEvent for "could a modified client abuse this."

### Phase 6 — Soft launch → grow toward 1k CCU
Launch to a small circle first, watch retention, fix what's broken, then push for growth (see Section 6).

### Phase 7 — Expand to Map 2 & 3
Sequenced deliberately after Map 1's core loop and task system are fully proven — not built in parallel from day one. Map 2/3 should mostly be reskinning existing task mechanics + each map's 1-2 signature tasks + a greybox pass, meaningfully faster than Map 1 since the reusable engine already exists.

**Total to first playable build:** you're already through Phases 0-3 and most of the way into 1.5. What's left before a genuinely playable loop: finish the map, build 4-5 real task minigames, then the lobby.

---

## 4. Luau architecture notes

- Use **ModuleScripts** for all game logic — keeps things testable and lets Claude help you edit one system without touching others.
- Use **RemoteEvents/RemoteFunctions** for every client→server action, validated server-side. Assume every client is hostile.
- Use **DataStoreService** (wrapped in a retry/pcall pattern) for saving currency + owned cosmetics — still pending, see Phase 3.
- Structure your Rojo project so scripts live in a normal folder tree in VS Code.

---

## 5. Look & feel

Recommend: **low-poly, flat-shaded, saturated colors**. Concretely:
- Characters: default Roblox avatars (R6, forced via Game Settings) with custom accessories/skins from your gacha.
- Map: simple geometric rooms, strong flat color-coding per room, free Toolbox props re-colored to match your palette rather than custom modeled.
- UI: rounded cards, bold color-coded rarity tiers (gray/blue/purple/gold) for gacha items.

---

## 6. Getting to 1,000 concurrent players

Roblox auto-scales servers, so CCU isn't a technical ceiling — it's an acquisition + retention problem:
- **Retention first, always.** Watch "did they play a 2nd round" above all else.
- **Icon + thumbnail** matter disproportionately on Roblox's discovery feed.
- **Short-form clips** (TikTok/YouTube Shorts) are the highest-leverage low-cost growth channel right now.
- **Roblox Ads** once retention is proven, not before.
- A small **Discord** for your playerbase drives repeat sessions and word-of-mouth.

---

## Summary of what NOT to build yet
No trading, no cosmetic-affecting-power items, no complex role variants (sheriff/engineer/etc.) — all v2+ once the core loop is proven fun and retaining players. Multiple maps are an explicit long-term goal, sequenced after Map 1 is fully proven (Phase 7), not built in parallel from day one.