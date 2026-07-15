# Suspect — Rojo Project

## What's in here
- `default.project.json` — tells Rojo how this folder maps into Roblox Studio.
- `src/ServerScriptService/Services/` — server-only game logic (roles, powerups, gacha).
- `src/ReplicatedStorage/Modules/` — shared code (currently just `Remotes.lua`).
- `src/ReplicatedStorage/Remotes/` — empty; Remotes are created at runtime by `Remotes.CreateAll()`, don't add files here.
- `src/StarterPlayer/StarterPlayerScripts/` — empty for now; client-side UI/input scripts go here next.

## One-time setup
1. Install [Rojo](https://rojo.space/) — either the VS Code extension **or** `cargo install rojo` / the standalone binary. VS Code extension is easiest if you're not already comfortable with a terminal.
2. In Roblox Studio: **Toolbox → Plugins → search "Rojo"** and install the Rojo plugin. This is what lets Studio receive the sync from your editor.
3. Open this folder in VS Code.

## Every time you work on it
1. In VS Code: `rojo serve` (or use the Rojo extension's "Start Server" button).
2. In Roblox Studio: open the Rojo plugin panel, click **Connect**.
3. Edit files in VS Code — changes appear in Studio automatically. Press Play in Studio to test.

## What's implemented right now
- Role assignment (Crewmate/Impostor), server-authoritative, with win-condition checking.
- Powerups with rarity variants (Common/Rare/Epic), server-resolved effects, cooldowns.
- Gacha rolling for powerup variants: weighted odds pulled from the *same* table the UI would display (so odds shown = odds used, no drift), plus a pity counter.
- A temporary currency stub (`player:SetAttribute("Currency", ...)`) so Gacha is testable before the real save system exists.

## Not yet built (next steps, in rough order)
1. **TaskManager** — the actual task minigames + completion reporting.
2. **KillSystem** — proximity + cooldown-checked kill RemoteEvent.
3. **MeetingSystem** — report body / emergency meeting / voting UI + tally.
4. **CurrencyService** — replace the attribute stub with real DataStore-backed currency (earned at match end).
5. **Lobby UI** — gacha machine screen showing odds (pull from `GachaService.GetDisclosure`), inventory, matchmaking queue.
6. Only 1 of the 4 powerup effect handlers (SpeedBoost) is actually implemented in `PowerupService.TryUse` — Decoy/VisionPulse/VentLock need their effect functions written in.

## A note on testing gacha/powerups locally
Studio's Play Solo won't let you fully test multiplayer role assignment — use **Test → Start** with multiple server/client instances (Studio's built-in local multiplayer test tool) once TaskManager and MeetingSystem exist, so you can actually play a round.
