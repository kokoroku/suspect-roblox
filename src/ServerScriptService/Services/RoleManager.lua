--[[
	RoleManager.lua
	Server-authoritative role assignment and life/death state.
	Nothing about role or alive-state should ever be trusted from the client -
	this module is the single source of truth, and other services (kill,
	voting, tasks) should ask it questions rather than track state themselves.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local DebugFlags = require(ServerScriptService.Services.DebugFlags)

local RoleManager = {}

-- player -> { role = "Crewmate" | "Impostor", alive = bool }
local playerState = {}

local IMPOSTOR_RATIO = 1 / 6 -- ~1 impostor per 6 players, tune later

-- Callbacks fired when a player's alive-state actually changes (not on fresh
-- AssignRoles construction). Lets other services (e.g. SpectateService) react
-- to deaths without RoleManager requiring them - keeps the dependency
-- one-directional and cycle-free.
local aliveChangedCallbacks = {}

function RoleManager.OnAliveChanged(callback)
	table.insert(aliveChangedCallbacks, callback)
end

function RoleManager.GetRole(player)
	local state = playerState[player]
	return state and state.role or nil
end

function RoleManager.IsAlive(player)
	local state = playerState[player]
	return state ~= nil and state.alive
end

function RoleManager.SetAlive(player, alive)
	local state = playerState[player]
	if state and state.alive ~= alive then
		state.alive = alive
		for _, callback in ipairs(aliveChangedCallbacks) do
			callback(player, alive)
		end
	end
end

function RoleManager.GetAllImpostors()
	local impostors = {}
	for player, state in pairs(playerState) do
		if state.role == "Impostor" then
			table.insert(impostors, player)
		end
	end
	return impostors
end

function RoleManager.GetAllCrew()
	local crew = {}
	for player, state in pairs(playerState) do
		if state.role == "Crewmate" then
			table.insert(crew, player)
		end
	end
	return crew
end

-- Call this at the start of a match with the list of players in the round.
function RoleManager.AssignRoles(playersInMatch)
	playerState = {}

	-- In debug all-impostor mode everyone is an impostor; otherwise ratio-based.
	local impostorCount = DebugFlags.ALL_IMPOSTORS and #playersInMatch or math.max(1, math.floor(#playersInMatch * IMPOSTOR_RATIO + 0.5))
	local shuffled = table.clone(playersInMatch)

	-- Fisher-Yates shuffle so impostor picks are unbiased
	for i = #shuffled, 2, -1 do
		local j = math.random(i)
		shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
	end

	for i, player in ipairs(shuffled) do
		local role = (i <= impostorCount) and "Impostor" or "Crewmate"
		playerState[player] = { role = role, alive = true }

		local roleEvent = Remotes.Get(Remotes.Names.RoleAssigned)
		-- Only tell each player their OWN role - never broadcast this
		roleEvent:FireClient(player, role)
	end
end

-- Returns "CrewWin", "ImpostorWin", or nil if the match should continue.
-- includeParity: when false, the impostors >= crew parity win is skipped (used
-- for task-completion checks, which can't change alive counts - see MatchService).
function RoleManager.CheckWinCondition(tasksRemaining, includeParity)
	local aliveImpostors, aliveCrew = 0, 0
	for _, state in pairs(playerState) do
		if state.alive then
			if state.role == "Impostor" then
				aliveImpostors += 1
			else
				aliveCrew += 1
			end
		end
	end

	if aliveImpostors == 0 then
		return "CrewWin"
	elseif includeParity and aliveImpostors >= aliveCrew then
		return "ImpostorWin"
	elseif tasksRemaining ~= nil and tasksRemaining <= 0 then
		return "CrewWin"
	end

	return nil
end

Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil
end)

return RoleManager
