--[[
	TaskManager.lua
	Tracks which tasks exist, assigns a subset to each crew player, and
	tracks completion. Server-authoritative - completion only happens
	through TaskManager.CompleteTask, called from a server-side trigger
	(see TaskStationHandler.server.lua), never directly from the client.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)

local TaskManager = {}

-- Populated at runtime as TaskStationHandler finds tagged parts in Workspace.
local allTaskIds = {}

-- player -> { [taskId] = true/false }
local assignments = {}

local TASKS_PER_PLAYER = 3

-- Stations tagged AFTER match start still register here, but they belong to
-- no one until the next AssignTasks call.
function TaskManager.RegisterTaskId(taskId)
	if not table.find(allTaskIds, taskId) then
		table.insert(allTaskIds, taskId)
	end
end

-- Call at match start with the list of crew players.
function TaskManager.AssignTasks(crewPlayers)
	assignments = {}

	if #allTaskIds == 0 then
		warn("[TaskManager] No task stations registered - every crew player gets 0 tasks, so GetRemainingCount() reads 0 and the crew task win condition counts as already complete.")
	end

	for _, player in ipairs(crewPlayers) do
		local shuffled = table.clone(allTaskIds)
		for i = #shuffled, 2, -1 do
			local j = math.random(i)
			shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
		end

		local assigned = {}
		for i = 1, math.min(TASKS_PER_PLAYER, #shuffled) do
			assigned[shuffled[i]] = false
		end
		assignments[player] = assigned

		local tasksEvent = Remotes.Get(Remotes.Names.TasksUpdated)
		-- Only ever send a player their OWN task list
		tasksEvent:FireClient(player, assigned)
	end
end

-- Returns { [taskId] = true/false } for a given player, or nil if unassigned.
function TaskManager.GetPlayerTasks(player)
	return assignments[player]
end

function TaskManager.CompleteTask(player, taskId)
	local playerTasks = assignments[player]
	if not playerTasks or playerTasks[taskId] == nil then
		return false, "NotAssigned"
	end
	if playerTasks[taskId] == true then
		return false, "AlreadyDone"
	end

	playerTasks[taskId] = true

	local tasksEvent = Remotes.Get(Remotes.Names.TasksUpdated)
	tasksEvent:FireClient(player, playerTasks)

	return true
end

-- Used by RoleManager.CheckWinCondition to know if crew has finished.
function TaskManager.GetRemainingCount()
	local remaining = 0
	for _, playerTasks in pairs(assignments) do
		for _, done in pairs(playerTasks) do
			if not done then
				remaining += 1
			end
		end
	end
	return remaining
end

Players.PlayerRemoving:Connect(function(player)
	assignments[player] = nil
end)

return TaskManager
