--[[
	Bootstrap.server.lua
	Boot script: creates all RemoteEvents, then wires client requests to the
	relevant service. Keep this file thin - it should just be plumbing.
	Actual logic lives in the individual Service modules.

	NOTE: deliberately NOT named "Init.server.lua" - Rojo treats a file
	named init.server.lua (case-insensitive) as making its parent folder
	INTO the script itself, which breaks script.Parent-based requires.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
Remotes.CreateAll()

local PowerupService = require(script.Parent.PowerupService)
local PowerupOwnershipService = require(script.Parent.PowerupOwnershipService)
local LoadoutService = require(script.Parent.LoadoutService)
local GachaService = require(script.Parent.GachaService)
local RoleManager = require(script.Parent.RoleManager)
local TaskManager = require(script.Parent.TaskManager)
local KillSystem = require(script.Parent.KillSystem)
local MeetingSystem = require(script.Parent.MeetingSystem)

-- ============================================================
-- UsePowerup
-- ============================================================
Remotes.Get(Remotes.Names.UsePowerup).OnServerEvent:Connect(function(player, powerupId)
	local success, reason = PowerupService.TryUse(player, powerupId)
	if not success then
		warn(player.Name, "failed to use", powerupId, "-", reason)
	end
end)

-- ============================================================
-- RollGacha
-- ============================================================
Remotes.Get(Remotes.Names.RollGacha).OnServerEvent:Connect(function(player, powerupId)
	local success, result, variant = GachaService.Roll(player, powerupId)
	Remotes.Get(Remotes.Names.GachaResult):FireClient(player, success, result, variant)
end)

-- ============================================================
-- SetLoadout - client sends a list of up to 2 powerup IDs they own
-- ============================================================
Remotes.Get(Remotes.Names.SetLoadout).OnServerEvent:Connect(function(player, powerupIds)
	local success, reason = LoadoutService.SetLoadout(player, powerupIds)
	Remotes.Get(Remotes.Names.LoadoutResult):FireClient(player, success, reason)
end)

-- ============================================================
-- AttemptKill - client sends who they're trying to kill
-- ============================================================
Remotes.Get(Remotes.Names.AttemptKill).OnServerEvent:Connect(function(player, targetPlayer)
	if not targetPlayer or not targetPlayer:IsA("Player") then
		warn(player.Name, "sent an invalid AttemptKill target")
		return
	end

	local success, reason = KillSystem.AttemptKill(player, targetPlayer)
	if not success then
		warn(player.Name, "failed to kill", targetPlayer.Name, "-", reason)
	end
end)

-- ============================================================
-- CallMeeting - emergency meeting button (bound to M on the client)
-- ============================================================
Remotes.Get(Remotes.Names.CallMeeting).OnServerEvent:Connect(function(player)
	local success, reason = MeetingSystem.StartMeeting(player, "Emergency", nil)
	if not success then
		warn(player.Name, "failed to call meeting -", reason)
	end
end)

-- ============================================================
-- CastVote - client sends a target player name, or nil/false to Skip
-- ============================================================
Remotes.Get(Remotes.Names.CastVote).OnServerEvent:Connect(function(player, targetName)
	local success, reason = MeetingSystem.CastVote(player, targetName)
	if not success then
		warn(player.Name, "failed to cast vote -", reason)
	end
end)

-- ============================================================
-- Starter currency + TEMP task/role assignment for solo testing.
-- Real match-start flow (lobby -> round begins -> assign roles + tasks
-- together) replaces this block once a proper round-reset flow exists.
-- ============================================================
Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("Currency", 500)
	task.wait(1)
	TaskManager.AssignTasks(Players:GetPlayers())
	-- Real ratio-based role assignment (RoleManager decides ~1 impostor
	-- per 6 players, minimum 1). Re-running this on every join is a TEMP
	-- stand-in for a proper match-start flow, which round-reset will replace.
	RoleManager.AssignRoles(Players:GetPlayers())
end)

print("[Suspect] Services initialized.")