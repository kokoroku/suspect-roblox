--[[
	TaskDefs.lua
	Shared task data (server + client both require this - it has no requires of
	its own so it stays cycle-free and safe to pull in from anywhere).

	Notes on the fields:
	  - displayName: the Estate skin. These names are themed for map 1 (The
	    Estate); per-map name switching (maps 2/3) comes with those maps.
	  - length: "Short" or "Long" - drives how many of each a player is assigned
	    per match (see TaskManager profiles). Long/short currently differ ONLY in
	    assignment counts; the placeholders all take equal time.
	  - module: the name of a ModuleScript in StarterPlayerScripts/TaskMinigames.
	    Everything is "Placeholder" until each real minigame is implemented - each
	    minigame updates its OWN entry here when it lands.
	  - minDuration: an anti-exploit floor (seconds), NOT gameplay pacing. It gets
	    retuned per minigame when that real minigame is built. 1 is a placeholder.
	  - config: per-minigame tuning table, passed straight to module.Build.
]]

local TaskDefs = {}

TaskDefs.Types = {
	-- ---- Short tasks ----
	-- minDuration: fastest legitimate clear is ~2.5-3s, so 2 is a pure anti-exploit floor.
	WireSplice = { displayName = "Rewire the Chandelier", length = "Short", module = "WireSplice", minDuration = 2, config = {} },
	DialMatch = { displayName = "Tune the Gramophone", length = "Short", module = "Placeholder", minDuration = 1, config = {} },
	HoldFill = { displayName = "Fill the Oil Lamps", length = "Short", module = "Placeholder", minDuration = 1, config = {} },
	SliderSync = { displayName = "Trim the Gas Lamps", length = "Short", module = "Placeholder", minDuration = 1, config = {} },
	PrecisionPins = { displayName = "Pick the Cabinet Lock", length = "Short", module = "Placeholder", minDuration = 1, config = {} },
	SortStow = { displayName = "Shelve the Library Books", length = "Short", module = "Placeholder", minDuration = 1, config = {} },

	-- ---- Long tasks ----
	-- minDuration: forced playback alone takes ~6s and a legitimate clear ~9-12s, so 6 is a pure anti-exploit floor.
	EchoCode = { displayName = "Play Back the Piano Refrain", length = "Long", module = "EchoCode", minDuration = 6, config = {} },
	ScrubDown = { displayName = "Polish the Silverware", length = "Long", module = "Placeholder", minDuration = 1, config = {} },
	SpotCheck = { displayName = "Find the Master's Keys", length = "Long", module = "Placeholder", minDuration = 1, config = {} },
	FlowRoute = { displayName = "Mend the Boiler Pipes", length = "Long", module = "Placeholder", minDuration = 1, config = {} },

	-- ---- Fallback ----
	Generic = { displayName = "Do the Task", length = "Short", module = "Placeholder", minDuration = 1, config = {} },
}

-- Returns the def for a taskType, or the Generic fallback if unknown/nil.
function TaskDefs.Get(taskType)
	return TaskDefs.Types[taskType] or TaskDefs.Types.Generic
end

return TaskDefs
