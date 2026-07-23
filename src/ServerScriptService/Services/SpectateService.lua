--[[
	SpectateService.lua
	Tells dead players who they're allowed to spectate. Whenever a player's
	alive-state changes (or a player leaves), it recomputes the list of living
	players and pushes it to every dead player so their spectate camera can
	cycle through valid targets.

	Side-effect service: it wires itself up via RoleManager.OnAliveChanged on
	require, so simply requiring it (from Bootstrap) is what activates it. It
	must NOT require KillSystem, MeetingSystem, or MatchService - the
	OnAliveChanged hook is the one-directional, cycle-free channel instead.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RoleManager = require(ServerScriptService.Services.RoleManager)
local Remotes = require(ReplicatedStorage.Modules.Remotes)
-- Cycle-safe: MatchService requires RoleManager/TaskManager/Remotes/DebugFlags,
-- never SpectateService.
local MatchService = require(ServerScriptService.Services.MatchService)

local SpectateService = {}

-- SECURITY/DESIGN RULE: the invariant is that ALIVE ROLE-HOLDERS never receive
-- SpectateTargetsUpdated - they must not learn death/alive info they didn't
-- witness, or exploiters could detect kills before a body is reported. Dead
-- players AND roleless spectators (late joiners) both may receive it.
local function broadcastToDead()
	local aliveNames = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if RoleManager.GetRole(player) ~= nil and RoleManager.IsAlive(player) then
			table.insert(aliveNames, player.Name)
		end
	end

	local targetsEvent = Remotes.Get(Remotes.Names.SpectateTargetsUpdated)
	for _, player in ipairs(Players:GetPlayers()) do
		if not (RoleManager.GetRole(player) ~= nil and RoleManager.IsAlive(player)) then
			targetsEvent:FireClient(player, aliveNames)
		end
	end
end

RoleManager.OnAliveChanged(function()
	broadcastToDead()
end)

Players.PlayerRemoving:Connect(function()
	-- An alive player leaving shrinks every ghost's target list. Defer so the
	-- leaving player has fully dropped out of Players:GetPlayers() first.
	task.defer(broadcastToDead)
end)

Players.PlayerAdded:Connect(function()
	-- A late joiner during a live match is a roleless spectator and needs the
	-- target list. Fire now and again shortly after - their client's listeners
	-- may not be connected yet at join time (same reason as the status snapshot).
	if MatchService.GetState() == "InProgress" then
		task.defer(broadcastToDead)
		task.delay(3, function()
			if MatchService.GetState() == "InProgress" then
				broadcastToDead()
			end
		end)
	end
end)

return SpectateService
