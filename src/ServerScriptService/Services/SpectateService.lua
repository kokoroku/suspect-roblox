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

local SpectateService = {}

-- SECURITY/DESIGN RULE: SpectateTargetsUpdated is ONLY ever fired to dead
-- players. Living clients must never receive death/alive information they
-- didn't witness, or exploiters could detect kills before a body is reported.
-- Late joiners (no role) get nothing.
local function broadcastToDead()
	local aliveNames = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if RoleManager.GetRole(player) ~= nil and RoleManager.IsAlive(player) then
			table.insert(aliveNames, player.Name)
		end
	end

	local targetsEvent = Remotes.Get(Remotes.Names.SpectateTargetsUpdated)
	for _, player in ipairs(Players:GetPlayers()) do
		if RoleManager.GetRole(player) ~= nil and not RoleManager.IsAlive(player) then
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

return SpectateService
