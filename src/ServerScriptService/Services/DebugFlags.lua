--[[
	DebugFlags.lua
	THE one place to flip debug/testing behavior. Every flag here must
	be false before shipping. Nothing else in the codebase should
	define its own debug toggles - add new flags here instead.
]]

local DebugFlags = {}

-- true = every player is assigned Impostor at match start, and
-- impostors are allowed to kill each other. For testing kill/meeting
-- flow without needing 6+ players. MUST be false to ship.
DebugFlags.ALL_IMPOSTORS = false

return DebugFlags
