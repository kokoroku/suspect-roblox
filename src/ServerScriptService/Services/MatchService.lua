--[[
	MatchService.lua
	Owns the match lifecycle: starting a round, evaluating the win condition on
	every relevant trigger (kills, meeting resolution, task completion), the
	MatchEnded broadcast, a timed end screen, then an in-place restart.

	IMPORTANT: this module must NEVER require KillSystem, MeetingSystem, or
	PowerupService - those require MatchService. The OnMatchStart hook is the
	reverse channel that keeps the dependency one-directional and cycle-free:
	those services register a reset callback here rather than MatchService
	reaching into their internals.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local RoleManager = require(ServerScriptService.Services.RoleManager)
local TaskManager = require(ServerScriptService.Services.TaskManager)
local DebugFlags = require(ServerScriptService.Services.DebugFlags)

local MatchService = {}

local END_SCREEN_DURATION = 10 -- seconds the end screen shows before restart

local matchState = "Waiting" -- "Waiting" | "InProgress" | "Ended"

function MatchService.GetState()
	return matchState
end

-- Callbacks fired when a match starts. Lets other services reset their own
-- state (bodies cleared, cooldowns wiped, meeting flags reset) without
-- MatchService requiring them - keeps the dependency one-directional and
-- cycle-free.
local onMatchStartCallbacks = {}

function MatchService.OnMatchStart(callback)
	table.insert(onMatchStartCallbacks, callback)
end

function MatchService.StartMatch()
	matchState = "InProgress"

	-- Services reset their own state here (bodies cleared, cooldowns wiped,
	-- meeting flags reset) so MatchService doesn't need to know their internals.
	for _, callback in ipairs(onMatchStartCallbacks) do
		callback()
	end

	-- CharacterAutoLoads is off, so this is the (re)spawn for every player.
	for _, player in ipairs(Players:GetPlayers()) do
		player:LoadCharacter()
	end

	RoleManager.AssignRoles(Players:GetPlayers())
	TaskManager.AssignTasks(RoleManager.GetAllCrew())
end

-- trigger: "Kill" | "MeetingResolved" | "TaskCompleted"
function MatchService.EvaluateWinCondition(trigger)
	if matchState ~= "InProgress" then
		return
	end

	local total = TaskManager.GetTotalCount()
	-- nil = "no tasks exist this match, the task clause must not fire" -
	-- CheckWinCondition already treats nil that way. Guards the zero-stations
	-- case from instantly ending every match.
	local tasksRemaining = total > 0 and TaskManager.GetRemainingCount() or nil

	-- Completing a task never changes alive counts, so it must never be able to
	-- hand impostors a parity (impostors >= crew) win. This also keeps 2-player
	-- test rounds playable - in a 1v1, parity is true from the first second, and
	-- without this gate the first task completion would instantly end the match
	-- as an impostor win.
	local includeParity = trigger ~= "TaskCompleted"

	local winner = RoleManager.CheckWinCondition(tasksRemaining, includeParity)

	if winner and DebugFlags.ALL_IMPOSTORS then
		-- ALL_IMPOSTORS mode exists to free-test kills and meetings; ending on
		-- every kill would make it useless. Report the would-be winner and stay
		-- in progress.
		print("[MatchService] Win condition reached (ignored in ALL_IMPOSTORS debug mode):", winner)
		return
	elseif winner then
		MatchService.EndMatch(winner)
	end
end

function MatchService.EndMatch(winner)
	matchState = "Ended"

	Remotes.Get(Remotes.Names.MatchEnded):FireAllClients(winner, END_SCREEN_DURATION)

	-- PLACEHOLDER: THIS line is what lobby teleportation replaces later - for
	-- now the match simply restarts in place so the game stays continuously
	-- playable.
	task.delay(END_SCREEN_DURATION, MatchService.StartMatch)
end

TaskManager.OnTaskCompleted(function()
	MatchService.EvaluateWinCondition("TaskCompleted")
end)

return MatchService
