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
local KillSystem = require(script.Parent.KillSystem)
local MeetingSystem = require(script.Parent.MeetingSystem)
local MatchService = require(script.Parent.MatchService)
local DebugFlags = require(script.Parent.DebugFlags)
-- Side-effect service: requiring it is what activates its dead-player broadcasts.
local SpectateService = require(script.Parent.SpectateService)

if DebugFlags.ALL_IMPOSTORS then
	warn("[Suspect] DEBUG MODE: ALL_IMPOSTORS is ON (DebugFlags.lua) - everyone will be an impostor. Do not ship.")
end

-- Seconds to wait after the first player joins before starting the match,
-- so anyone joining alongside them is included in role/task assignment.
local MATCH_START_GRACE = 5
local firstMatchScheduled = false

-- ============================================================
-- Manual respawn control. Roblox auto-respawns characters a few seconds
-- after death by default - that's what was undoing your kills/ejections.
-- Turning this off means WE decide when a character (re)spawns, which is
-- also the right foundation for ghost mode later (dead players staying
-- as their ragdoll/a ghost instead of popping back in).
-- ============================================================
Players.CharacterAutoLoads = false

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
	local success, result, variant, rollStatus = GachaService.Roll(player, powerupId)
	Remotes.Get(Remotes.Names.GachaResult):FireClient(player, success, result, variant, rollStatus)
end)

-- ============================================================
-- GetGachaCatalog (RemoteFunction) - client asks for the full gacha snapshot
-- ============================================================
Remotes.Get(Remotes.FunctionNames.GetGachaCatalog).OnServerInvoke = function(player)
	return GachaService.GetCatalog(player)
end

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
-- Player join: manual spawn (since CharacterAutoLoads is off). Bootstrap only
-- decides WHEN the FIRST match starts - MATCH_START_GRACE seconds after the
-- first player joins - and then hands off to MatchService, which owns role/task
-- assignment and every restart afterward (self-scheduled by MatchService.EndMatch).
--
-- TEMPORARY: this one-shot first-match trigger stands in for the real
-- lobby/round-begin flow. Late joiners mid-match still spawn roleless until the
-- next round - RoleManager returns nil/false for them, so KillSystem's guards
-- mean they can't kill or be killed. Still acceptable for now.
-- ============================================================
Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("Currency", 500)
	player:LoadCharacter() -- manual spawn, required now that CharacterAutoLoads is false

	if firstMatchScheduled then
		return -- first match already scheduled/running; latecomers spawn roleless until the next round
	end
	firstMatchScheduled = true

	task.delay(MATCH_START_GRACE, MatchService.StartMatch)
end)

print("[Suspect] Services initialized.")