--[[
	TaskManager.lua
	Tracks which tasks exist, assigns a subset to each crew player, and
	tracks completion. Server-authoritative - completion only happens
	through TaskManager.TryFinish (validated), driven by a client TaskFinished
	request routed through Bootstrap, never trusted directly from the client.

	Dependency note (cycle-safety): this module requires TaskDefs and RoleManager
	only. RoleManager itself requires only Remotes, so that's safe. TaskManager
	must NEVER require MatchService or MeetingSystem: MatchService requires
	TaskManager, and MeetingSystem requires MatchService, so requiring either here
	would create a cycle. Reactions that need those (e.g. clearing sessions on
	meeting start) are wired from the composition root (Bootstrap) instead.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local TaskDefs = require(ReplicatedStorage.Modules.TaskDefs)
local RoleManager = require(ServerScriptService.Services.RoleManager)

local TaskManager = {}

-- Populated at runtime as TaskStationHandler finds tagged parts in Workspace.
local allTaskIds = {}

-- taskId -> the station Part, and taskId -> its taskType string.
local stationParts = {}
local taskTypes = {}

-- player -> { [taskId] = { done = bool, taskType = string } }
local assignments = {}

-- player -> { taskId = string, startClock = number }. One live task session
-- per player; starting a new one silently replaces any previous.
local sessions = {}

-- Profiles are {short, long} counts per player. AssignTasks picks a random
-- profile each match that differs from the previous one, so consecutive
-- matches never roll the same mix.
local MATCH_TASK_PROFILES = { { short = 6, long = 1 }, { short = 5, long = 2 }, { short = 4, long = 3 } }
local lastProfileIndex = nil

-- How close (studs) a player's HumanoidRootPart must be to the station to
-- finish - anti-teleport / anti-remote-spoof floor.
local COMPLETE_RANGE = 12

-- Callbacks fired whenever a task is completed. Lets MatchService re-check the
-- win condition on task completion without TaskManager requiring it - keeps the
-- dependency one-directional and cycle-free.
local taskCompletedCallbacks = {}

function TaskManager.OnTaskCompleted(callback)
	table.insert(taskCompletedCallbacks, callback)
end

-- Stations tagged AFTER match start still register here, but they belong to
-- no one until the next AssignTasks call.
function TaskManager.RegisterTaskId(taskId, part, taskType)
	if not table.find(allTaskIds, taskId) then
		table.insert(allTaskIds, taskId)
	end
	stationParts[taskId] = part
	taskTypes[taskId] = taskType
end

-- Fisher-Yates shuffle in place.
local function shuffle(list)
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
end

-- Call at match start with the list of crew players.
function TaskManager.AssignTasks(crewPlayers)
	assignments = {}
	sessions = {}

	if #allTaskIds == 0 then
		warn("[TaskManager] No task stations registered - every crew player gets 0 tasks, so GetRemainingCount() reads 0 and the crew task win condition counts as already complete.")
	end

	-- Pick a profile that differs from last match's.
	local profileIndex
	repeat
		profileIndex = math.random(#MATCH_TASK_PROFILES)
	until profileIndex ~= lastProfileIndex
	lastProfileIndex = profileIndex
	local profile = MATCH_TASK_PROFILES[profileIndex]
	print(string.format("[TaskManager] Rolled task profile #%d: %d short + %d long per player", profileIndex, profile.short, profile.long))

	-- Split every registered task into short/long pools by its def length.
	local shortIds, longIds = {}, {}
	for _, taskId in ipairs(allTaskIds) do
		if TaskDefs.Get(taskTypes[taskId]).length == "Long" then
			table.insert(longIds, taskId)
		else
			table.insert(shortIds, taskId)
		end
	end

	if #shortIds < profile.short then
		warn(string.format("[TaskManager] Only %d short stations exist but profile wants %d - players will get fewer shorts.", #shortIds, profile.short))
	end
	if #longIds < profile.long then
		warn(string.format("[TaskManager] Only %d long stations exist but profile wants %d - players will get fewer longs.", #longIds, profile.long))
	end

	for _, player in ipairs(crewPlayers) do
		local shortPool = table.clone(shortIds)
		local longPool = table.clone(longIds)
		shuffle(shortPool)
		shuffle(longPool)

		local assigned = {}
		for i = 1, math.min(profile.short, #shortPool) do
			local taskId = shortPool[i]
			assigned[taskId] = { done = false, taskType = taskTypes[taskId] }
		end
		for i = 1, math.min(profile.long, #longPool) do
			local taskId = longPool[i]
			assigned[taskId] = { done = false, taskType = taskTypes[taskId] }
		end
		assignments[player] = assigned

		local tasksEvent = Remotes.Get(Remotes.Names.TasksUpdated)
		-- Only ever send a player their OWN task list
		tasksEvent:FireClient(player, assigned)
	end
end

-- Returns { [taskId] = { done, taskType } } for a given player, or nil.
function TaskManager.GetPlayerTasks(player)
	return assignments[player]
end

-- Shared completion logic: mark done, notify the client, run callbacks.
function TaskManager.CompleteTask(player, taskId)
	local playerTasks = assignments[player]
	if not playerTasks or playerTasks[taskId] == nil then
		return false, "NotAssigned"
	end
	if playerTasks[taskId].done == true then
		return false, "AlreadyDone"
	end

	playerTasks[taskId].done = true

	local tasksEvent = Remotes.Get(Remotes.Names.TasksUpdated)
	tasksEvent:FireClient(player, playerTasks)

	for _, callback in ipairs(taskCompletedCallbacks) do
		callback()
	end

	return true
end

-- Open a task session. Rejects unknown/unassigned/already-done tasks. Starting
-- a new session silently replaces any previous one for this player.
function TaskManager.StartSession(player, taskId)
	if not table.find(allTaskIds, taskId) then
		return false, "UnknownTask"
	end
	local playerTasks = assignments[player]
	if not playerTasks or playerTasks[taskId] == nil then
		return false, "NotAssigned"
	end
	if playerTasks[taskId].done == true then
		return false, "AlreadyDone"
	end

	sessions[player] = { taskId = taskId, startClock = os.clock() }
	return true
end

-- Validate and finish an open session. On success, clears the session and runs
-- the shared CompleteTask logic.
function TaskManager.TryFinish(player, taskId)
	local session = sessions[player]
	if not session or session.taskId ~= taskId then
		return false, "NoSession"
	end

	if os.clock() - session.startClock < TaskDefs.Get(taskTypes[taskId]).minDuration then
		return false, "TooFast"
	end

	local part = stationParts[taskId]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not part or not root or (root.Position - part.Position).Magnitude > COMPLETE_RANGE then
		return false, "TooFar"
	end

	sessions[player] = nil
	return TaskManager.CompleteTask(player, taskId)
end

-- Clear every live session (e.g. at meeting start, wired from Bootstrap).
function TaskManager.ClearAllSessions()
	sessions = {}
end

-- Used by RoleManager.CheckWinCondition to know if crew has finished.
function TaskManager.GetRemainingCount()
	local remaining = 0
	for _, playerTasks in pairs(assignments) do
		for _, entry in pairs(playerTasks) do
			if not entry.done then
				remaining += 1
			end
		end
	end
	return remaining
end

-- Total number of assigned tasks across all players, regardless of done state.
function TaskManager.GetTotalCount()
	local total = 0
	for _, playerTasks in pairs(assignments) do
		for _ in pairs(playerTasks) do
			total += 1
		end
	end
	return total
end

-- A dead player can't finish tasks - drop any live session so it can't be
-- completed post-mortem (e.g. a lingering client TaskFinished).
RoleManager.OnAliveChanged(function(player, alive)
	if not alive then
		sessions[player] = nil
	end
end)

Players.PlayerRemoving:Connect(function(player)
	assignments[player] = nil
	sessions[player] = nil
end)

return TaskManager
