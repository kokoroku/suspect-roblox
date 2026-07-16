# "Suspect" — Roblox Dev Roadmap (Idea → Playable Game)

## Name check
"Suspect" is solid — short, readable, on-theme, easy to search. A couple of backups in case it's taken or you want more flavor: **Suspicion**, **Sus HQ**, **The Setup**, **Codename: Sus**. I'd stick with Suspect unless the Roblox name is unavailable.

---

## 1. Tools (kept deliberately minimal)

| Tool | Purpose | Cost |
|---|---|---|
| **Roblox Studio** | The engine. Non-negotiable. | Free |
| **VS Code + Rojo** | Lets you write Luau in a real editor (with Claude Code helping you write/refactor scripts) and sync it into Studio. Also gives you real version control instead of Studio's fragile built-in history. | Free |
| **GitHub** | Version control + backup. Rojo syncs a filesystem folder structure to Studio, so a normal git repo works. | Free |
| **Claude (this chat, or Claude Code in VS Code)** | Writing/debugging Luau ModuleScripts, RemoteEvent architecture, gacha probability math, UI logic. | You already have it |
| **Photopea or Figma** | UI mockups, icons, thumbnail, gacha item cards. Browser-based, no install. | Free |
| **Roblox Toolbox (built into Studio)** | Free community models/meshes for props so you're not modeling everything from scratch. | Free |

That's it — 5 tools. Skip Blender entirely for the MVP; you don't need custom 3D modeling to hit "playable game fast." Use Studio's built-in parts + free Toolbox assets, and only bring in Blender later if you want a signature look once the core loop is proven fun.

---

## 2. Core game loop (design this first — everything else serves it)

This is the actual engine of your retention and growth, so get it right before writing a line of code:

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
- **Powerups** = rollable via gacha as **rarity variants of the same ability** (e.g. Speed Boost: Common/Rare/Epic) — rarity changes *degree* (duration/strength), never *access*. On top of that, players **equip exactly 2 powerups from their owned collection before each match**, chosen in the lobby rather than found mid-round. This is the key change to the loop: it turns powerups into a genuine loadout/build decision (which 2 out of your growing collection actually synergize?) instead of a random pickup, which gives the game a real skill ceiling (mastering combos) on top of the collection loop, and gives players a reason to keep coming back to try new combinations as their collection grows. Roll currency is earned through play by default (Robux top-up optional, never required), odds are always shown before rolling, and a pity counter guarantees a Rare+ within a set number of rolls — keeping this satisfying without becoming pay-to-win, since a skilled 2-powerup combo at Common rarity should still be able to beat a poorly-chosen combo of Epics.

This is also why the game stays fun to watch and stream — loadout choices are visible and debatable, nobody's flatly locked out of an ability, and nobody's mad about losing to someone's wallet alone.

---

## 3. Roadmap (idea → playable)

### Phase 0 — Setup & scope lock (1–2 days)
- Install Studio, set up Rojo project + GitHub repo.
- Lock your MVP scope hard: **1 map, 1 impostor count option (1 impostor for X players), 4–5 tasks, 4 powerups, 6 gacha cosmetics.** Everything else is post-launch. The #1 killer of solo/small-team Roblox projects is scope creep before anything is playable.
- Decide art direction now (see Section 5) so you're not re-doing assets later.

### Phase 1 — Core loop prototype (1.5–2 weeks)
This is the Among Us skeleton. Build it server-authoritative from day one (don't retrofit anti-exploit later, it's painful):
- **RoleManager** (ModuleScript): assigns Impostor/Crewmate on match start, tracks alive/dead state server-side only — never trust the client with role info it shouldn't see.
- **TaskManager** (ModuleScript): each task is its own minigame script (wiring, simple pattern-match, a fill-the-bar, etc.) that reports completion via a RemoteEvent the server validates.
- **KillSystem**: server checks proximity + cooldown before allowing a kill RemoteEvent to succeed — never let the client just say "I killed player X."
- **MeetingSystem**: report body / emergency button → freezes players → opens a voting GUI → server tallies votes → ejects.
- **Win condition checker**: runs after every kill/task/vote to check crew-win, impostor-win, sabotage-win.

Build this on one small test map (a few rooms, corridors). Get it playable and boring-but-functional before touching powerups or art.

### Phase 2 — Powerups + loadout (4–6 days)
- Design 4 to start (expand later): e.g. **Speed Boost** (crew), **Decoy** (crew, drops a fake body), **Vision Pulse** (impostor, briefly reveals nearby players through walls), **Vent Lock** (crew, disables a vent temporarily).
- Build `PowerupService` as a table of effect functions keyed by powerup ID, server-side cooldowns, with rarity-variant stats (see Phase 3).
- Build a small `LoadoutService` alongside it: players **own** whatever powerups/variants they've unlocked via gacha (a permanent collection), and **equip exactly 2** as their active loadout before each match. Ownership and equipped-state are separate concerns on purpose — it's what makes "collection grows over time, but loadout is a real choice each match" work cleanly in code.

### Phase 3 — Currency + gacha (1 week)
- Soft currency awarded at match end (formula: base amount + task completion bonus + survival bonus + win bonus).
- Gacha machine in the lobby: a GUI showing rarity tiers and **odds displayed as percentages** (required by current Roblox policy for any paid random item — build this in from the start, it's easy now and painful to retrofit).
- Keep the actual randomization server-side (never let the client roll its own gacha pull) to prevent exploited "always rare" results.
- Recommend a pity system (guaranteed rare after N pulls) — proven to keep the loop satisfying without needing to be predatory.

### Phase 4 — Lobby, UI, art pass (1 week)
- Build the lobby as its own space: matchmaking queue, gacha machine, cosmetic preview/equip, leaderboard.
- Apply your art style consistently across map, characters, and UI (see Section 5).

### Phase 5 — Testing & hardening (3–5 days)
- Playtest with friends at real player counts (5–10 people) repeatedly — Among Us-style games live or die on pacing (task length, meeting length, map size).
- Server-side exploit pass: audit every RemoteEvent for "could a modified client abuse this."

### Phase 6 — Soft launch → grow toward 1k CCU
- Launch to a small circle first (Discord, friends, a small ad or two), watch retention (are people playing a 2nd round?), fix what's broken.
- Then push for growth (see Section 6).

**Total to first playable build: roughly 4–6 weeks solo**, if scope stays locked to what's above. That's realistic for a small, focused team or solo dev — the trap is adding more maps/roles/powerups before the core loop is proven fun.

---

## 4. Luau architecture notes (so you're not guessing structure)

- Use **ModuleScripts** for all game logic (RoleManager, TaskManager, PowerupService, GachaService, CurrencyService) — keeps things testable and lets Claude help you edit one system without touching others.
- Use **RemoteEvents/RemoteFunctions** for every client→server action, and validate everything server-side. Assume every client is hostile — Roblox exploiters are common and this is the #1 way small games get ruined.
- Use **DataStoreService** (wrapped in a retry/pcall pattern) for saving currency + owned cosmetics. Don't write your own save system from scratch — there are well-known safe patterns (e.g. ProfileService-style session locking) worth having Claude help you implement to avoid data loss on server shutdown.
- Structure your Rojo project so scripts live in a normal folder tree in VS Code — this is what lets you use Claude Code effectively instead of copy-pasting into Studio's script editor by hand.

---

## 5. Look & feel

Recommend: **low-poly, flat-shaded, saturated colors** — same spirit as Among Us's simplicity but built for Roblox's blocky avatar bodies rather than fighting them. Concretely:
- Characters: default Roblox avatars with custom accessories/skins from your gacha (don't build custom rigs — expensive and unnecessary for MVP).
- Map: simple geometric rooms, strong flat color-coding per room (so players orient instantly, same trick Among Us uses), free Toolbox props re-colored to match your palette rather than custom modeled.
- UI: rounded cards, bold color-coded rarity tiers (gray/blue/purple/gold) for gacha items — familiar gacha-game visual language players already read instantly.

This keeps art cost near zero while still looking intentional rather than "default Roblox gray blocks."

---

## 6. Getting to 1,000 concurrent players

Roblox auto-scales servers, so CCU isn't a technical ceiling for you — it's an acquisition + retention problem:
- **Retention first, always.** A game with great retention and no marketing beats a heavily-marketed game with a weak loop. Watch your Studio analytics for "did they play a 2nd round" above all else.
- **Icon + thumbnail** matter disproportionately on Roblox's discovery feed — invest real time here even before the game is finished.
- **Short-form clips** (TikTok/YouTube Shorts of funny impostor moments, gacha pulls) are the highest-leverage low-cost growth channel for Roblox games right now.
- **Roblox Ads** (Robux-funded) once retention is proven — don't spend on ads before the loop retains players, you'll just burn budget on a leaky bucket.
- A small **Discord** for your playerbase drives repeat sessions and word-of-mouth far more than people expect.

---

## Summary of what NOT to build yet
No trading, no multiple maps, no cosmetic-affecting-power items, no complex role variants (sheriff/engineer/etc. from Among Us mod culture) — all of that is v2 once the core loop is proven fun and retaining players. Ship the small version first.
