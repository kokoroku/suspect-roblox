--[[
	TaskStationHandler.server.lua
	Auto-wires EVERY Part tagged "TaskStation" in Workspace to TaskManager.
	You do not need to add a script to each task part - just tag it.
	Setup for a new task station (no scripting required):
	  1. Place a Part in Workspace, rename it uniquely (e.g. "Task_Wiring1")
	  2. Insert a ProximityPrompt into that part (right-click part in
	     Explorer -> Insert Object -> ProximityPrompt)
	  3. Tag the part with "TaskStation" - easiest way: paste this into
	     the Command Bar (View -> Command Bar) once per part:
	       game:GetService("CollectionService"):AddTag(workspace.Task_Wiring1, "TaskStation")
	     (swap "Task_Wiring1" for your part's actual name)
]]

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local TaskManager = require(ServerScriptService.Services.TaskManager)

local TAG = "TaskStation"

local function setupStation(part)
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		warn(part:GetFullName(), "is tagged TaskStation but has no ProximityPrompt - skipping")
		return
	end

	TaskManager.RegisterTaskId(part.Name)

	prompt.Triggered:Connect(function(player)
		local success, reason = TaskManager.CompleteTask(player, part.Name)
		if success then
			prompt.Enabled = false -- prevents re-triggering this round
			print(player.Name, "completed task:", part.Name, "- remaining:", TaskManager.GetRemainingCount())
		else
			warn(player.Name, "failed task", part.Name, "-", reason)
		end
	end)
end

for _, part in ipairs(CollectionService:GetTagged(TAG)) do
	setupStation(part)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(setupStation)
