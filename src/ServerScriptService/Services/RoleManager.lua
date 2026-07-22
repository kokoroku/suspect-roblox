--[[
	RoleManager.lua
	Server-authoritative role assignment and life/death state.
	Nothing about role or alive-state should ever be trusted from the client -
	this module is the single source of truth, and other services (kill,
	voting, tasks) should ask it questions rather than track state themselves.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)

local RoleManager = {}

-- player -> { role = "Crewmate" | "Impostor", alive = bool }
local playerState = {}

-- True only while RoleManager.DebugForceAllImpostor is active. KillSystem
-- checks this to skip the "impostors can't kill impostors" rule during
-- that specific test mode - that rule is correct for real games, it just
-- can't apply when everyone is deliberately Impostor for testing.
local debugAllImpostorMode = false

local IMPOSTOR_RATIO = 1 / 6 -- ~1 impostor per 6 players, tune later

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
	if state then
		state.alive = alive
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

function RoleManager.IsDebugAllImpostorMode()
	return debugAllImpostorMode
end

-- Call this at the start of a match with the list of players in the round.
function RoleManager.AssignRoles(playersInMatch)
	playerState = {}
	debugAllImpostorMode = false

	local impostorCount = math.max(1, math.floor(#playersInMatch * IMPOSTOR_RATIO + 0.5))
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

-- TESTING ONLY - forces every given player to Impostor, alive. Useful for
-- exercising kill/meeting flow with more than 1 impostor before real
-- matchmaking exists. Flip DEBUG_ALL_IMPOSTORS off in Bootstrap to go
-- back to normal ratio-based assignment - don't ship with this active.
function RoleManager.DebugForceAllImpostor(playersInMatch)
	playerState = {}
	debugAllImpostorMode = false

	for _, player in ipairs(playersInMatch) do
		playerState[player] = { role = "Impostor", alive = true }
		local roleEvent = Remotes.Get(Remotes.Names.RoleAssigned)
		roleEvent:FireClient(player, "Impostor")
	end
end

-- Returns "CrewWin", "ImpostorWin", or nil if the match should continue.
function RoleManager.CheckWinCondition(tasksRemaining)
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
	elseif aliveImpostors >= aliveCrew then
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
