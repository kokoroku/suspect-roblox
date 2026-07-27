--[[
	DebugFlags.lua
	THE one place debug/testing behavior is defined. Nothing else in the codebase
	should declare its own toggles - add new flags here instead.

	RUNTIME AND SESSION-ONLY AS OF THE DEBUG REHAUL. Every default below is false
	and THIS FILE IS NO LONGER EDITED TO TEST ANYTHING. DebugService mutates these
	fields at runtime from the in-game mod menu, so a flag is on only for as long
	as someone leaves it on; a server restart resets every one of them back to the
	defaults written here. That is the safety property: nothing can be committed
	on by accident, because turning something on is no longer a code change.

	CONSEQUENCE FOR CONSUMERS - the rule the whole rehaul rests on: read the field
	AT DECISION TIME, inside the function that acts on it. Never cache one into a
	local at require time and never branch on one at module scope. A cached read
	freezes the value at server boot, which is exactly what runtime toggling has
	to be able to change.

	The loud "this is on" warning lives on DebugService's toggle path now, not
	here - a flag that is false at boot has nothing to warn about, and the moment
	that matters is when someone flips it.
]]

local DebugFlags = {}

-- true = every player is assigned Impostor at match start, and impostors are
-- allowed to kill each other. For testing kill/meeting flow without needing 6+
-- players. Matches never end while this is on.
DebugFlags.ALL_IMPOSTORS = false

-- true = every joining player owns all powerups at max tier, for effect testing.
-- Applies at JOIN, so it affects players who join after it is switched on.
DebugFlags.GRANT_ALL_POWERUPS = false

-- true = pressing P toggles lights-out directly, bypassing the sabotage flow.
DebugFlags.LIGHTS_TEST_CONTROLS = false

-- true = every crew player receives EVERY registered task instead of a profile
-- roll. Read at task assignment, so it applies from the next match on.
DebugFlags.ASSIGN_ALL_TASKS = false

-- true = a loadout save takes effect on the ACTIVE set instantly, mid-match,
-- instead of staging for the next one. For verify sessions that need to cycle
-- through Charms without restarting a round between each.
--
-- The one flag whose danger is design-level, not just untidiness: the
-- pending/active split is LOAD-BEARING for the dual-face law (docs/DESIGN.md
-- section 7). Builds lock BEFORE roles are assigned, which is the entire reason
-- every Charm must be worth a slot to either role. A player who can re-pick
-- their loadout after learning their role brings a role-optimal build every
-- match, and the dual-face design stops meaning anything.
DebugFlags.LIVE_LOADOUT = false

-- true = mods cannot be killed. A mod target is rejected by the kill path
-- exactly as an invalid target is, so the killer's cooldown is never spent and
-- nothing about the attempt is special-cased downstream. For observing a match
-- from inside it without becoming the reason it ends.
DebugFlags.GOD_MODE = false

-- true = the intermission countdown runs 3 seconds instead of the full length.
-- Read when a countdown STARTS, so it applies from the next intermission on.
DebugFlags.FAST_INTERMISSION = false

-- true = cooldown GATES simply pass - charm cooldowns, the kill cooldown, the
-- shared sabotage cooldown, and Desecrate's independent timer. Per-match uses
-- (Augur's reads) are deliberately NOT bypassed - scarcity is part of what gets
-- tested.
DebugFlags.NO_COOLDOWNS = false

return DebugFlags
