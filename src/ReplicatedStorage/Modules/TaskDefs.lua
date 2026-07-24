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
	-- minDuration: floor raised to match the reworked design's slower legitimate clears; still pure anti-exploit, never gameplay pacing.
	DialMatch = { displayName = "Tune the Gramophone", length = "Short", module = "DialMatch", minDuration = 4, config = {} },
	-- minDuration: floor raised to match the reworked design's slower legitimate clears; still pure anti-exploit, never gameplay pacing.
	HoldFill = { displayName = "Fill the Oil Lamps", length = "Short", module = "HoldFill", minDuration = 3, config = {} },
	-- minDuration: anti-exploit floor.
	SliderSync = { displayName = "Trim the Gas Lamps", length = "Short", module = "SliderSync", minDuration = 2, config = {} },
	-- minDuration: pure anti-exploit floor, legit clears take 3-6s.
	PrecisionPins = { displayName = "Pick the Cabinet Lock", length = "Short", module = "PrecisionPins", minDuration = 2, config = {} },
	-- minDuration: anti-exploit floor.
	SortStow = { displayName = "Shelve the Library Books", length = "Short", module = "SortStow", minDuration = 3, config = {} },

	-- ---- Long tasks ----
	-- minDuration: forced playback alone takes ~6s and a legitimate clear ~9-12s, so 6 is a pure anti-exploit floor.
	EchoCode = { displayName = "Play Back the Piano Refrain", length = "Long", module = "EchoCode", minDuration = 6, config = {} },
	-- minDuration: anti-exploit floor well under a legit clear (~12-18s).
	ScrubDown = { displayName = "Polish the Silverware", length = "Long", module = "ScrubDown", minDuration = 6, config = {} },
	-- minDuration: anti-exploit floor well under a legit clear (~8-20s).
	SpotCheck = { displayName = "Find the Master's Keys", length = "Long", module = "SpotCheck", minDuration = 4, config = {} },
	-- minDuration: legit clears run ~15-30s; pure anti-exploit floor.
	FlowRoute = { displayName = "Mend the Boiler Pipes", length = "Long", module = "FlowRoute", minDuration = 6, config = {} },

	-- ---- Fix minigames (sabotage stations) ----
	-- These are NEVER assignable as tasks: task pools are built from the stations
	-- TaskManager registers, and fix stations register with SabotageService
	-- instead. They live here so the shared client task pipeline (TaskOpen ->
	-- module -> TaskFinished) can resolve their module/minDuration like any task.
	-- minDuration: puzzle floor; legit solves run ~4-10s, so this stays a pure
	-- anti-exploit floor.
	FixSwitches = { displayName = "Reset the Fuse Box", length = "Short", module = "FixSwitches", minDuration = 2, config = {} },
	-- minDuration: anti-exploit floor only.
	FixValve = { displayName = "Vent the Boiler", length = "Short", module = "FixValve", minDuration = 2, config = {} },

	-- ---- Fallback ----
	Generic = { displayName = "Do the Task", length = "Short", module = "Placeholder", minDuration = 1, config = {} },
}

-- Returns the def for a taskType, or the Generic fallback if unknown/nil.
function TaskDefs.Get(taskType)
	return TaskDefs.Types[taskType] or TaskDefs.Types.Generic
end

return TaskDefs
