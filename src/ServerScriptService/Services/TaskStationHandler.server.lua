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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
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

	-- The TaskType attribute selects which minigame/def this station uses.
	-- Missing attribute falls back to the Generic def so an untagged station
	-- still works (just as a plain "Do the Task").
	local taskType = part:GetAttribute("TaskType")
	if taskType == nil then
		warn(part:GetFullName(), "has no TaskType attribute - using the Generic fallback")
		taskType = "Generic"
	end

	-- Holding is gone: the prompt is now a single press that opens the minigame
	-- window client-side. HoldDuration 0 = instant trigger on press.
	prompt.HoldDuration = 0

	-- WORLD PROMPTS ARE E-ONLY BY DESIGN. Mouse clicks must NEVER start a task.
	-- ProximityPrompts are mouse-clickable by default, and GUI frames don't sink
	-- clicks, so clicks inside an open task window were leaking through to the
	-- station prompt behind it and RE-TRIGGERING it, restarting the session and
	-- rebuilding the minigame from zero. ClickablePrompt = false kills that here.
	-- KNOWN MOBILE DEBT: touch devices trigger a ProximityPrompt by TAPPING it, so
	-- with this off, mobile clients cannot start tasks until a per-platform input
	-- pass re-enables ClickablePrompt for TOUCH clients only.
	prompt.ClickablePrompt = false

	TaskManager.RegisterTaskId(part.Name, part, taskType)

	prompt.Triggered:Connect(function(player)
		-- Re-triggering an already-open task is a no-op, never a restart. The
		-- TaskCancel remote clears the session when the window closes, so a live
		-- session here means the window is genuinely still open - this can't wedge
		-- the station.
		if TaskManager.HasSession(player, part.Name) then
			return
		end

		-- Prompts stay physically visible; this is the server-side gate stopping
		-- task completion during meetings (players frozen at a station can still
		-- hold E) and during the end screen.
		if MatchService.GetState() ~= "InProgress" or MeetingSystem.IsMeetingActive() then
			warn(player.Name, "tried to complete a task while not in an active match/meeting-free round")
			return
		end

		-- Open a validated session and tell the client to pop the minigame; the
		-- actual completion comes back later via TaskFinished -> TaskManager.TryFinish.
		local ok, reason = TaskManager.StartSession(player, part.Name)
		if ok then
			Remotes.Get(Remotes.Names.TaskOpen):FireClient(player, part.Name, taskType, part.Position)
		else
			warn(player.Name, "failed task", part.Name, "-", reason)
		end
	end)
end

for _, part in ipairs(CollectionService:GetTagged(TAG)) do
	setupStation(part)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(setupStation)
