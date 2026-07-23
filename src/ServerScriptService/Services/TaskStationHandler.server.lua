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
local MeetingSystem = require(ServerScriptService.Services.MeetingSystem)
local MatchService = require(ServerScriptService.Services.MatchService)

local TAG = "TaskStation"

-- taskId (part name) -> the first part registered under it. Task IDs ARE part
-- names, so two differently-placed parts sharing a name silently collapse into
-- one logical task - completing either marks both done.
local seenParts = {}

local function setupStation(part)
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		warn(part:GetFullName(), "is tagged TaskStation but has no ProximityPrompt - skipping")
		return
	end

	local existing = seenParts[part.Name]
	if existing and existing ~= part then
		warn(
			"Duplicate TaskStation name:", existing:GetFullName(), "and", part:GetFullName(),
			"- both register as task ID '" .. part.Name .. "' and will act as ONE task (completing either completes both). Rename one."
		)
	else
		seenParts[part.Name] = part
	end

	TaskManager.RegisterTaskId(part.Name)

	prompt.Triggered:Connect(function(player)
		-- Prompts stay physically visible; this is the server-side gate stopping
		-- task completion during meetings (players frozen at a station can still
		-- hold E) and during the end screen.
		if MatchService.GetState() ~= "InProgress" or MeetingSystem.IsMeetingActive() then
			warn(player.Name, "tried to complete a task while not in an active match/meeting-free round")
			return
		end

		local success, reason = TaskManager.CompleteTask(player, part.Name)
		if success then
			-- Prompt stays enabled: assignments are per-player, so disabling it
			-- here would block every other player assigned this same station.
			-- TaskManager.CompleteTask rejects repeats/unassigned players anyway.
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
