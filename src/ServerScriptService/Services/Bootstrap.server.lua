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
local TaskManager = require(script.Parent.TaskManager)
local DebugFlags = require(script.Parent.DebugFlags)
-- Side-effect service: requiring it is what activates its dead-player broadcasts.
local SpectateService = require(script.Parent.SpectateService)
-- Side-effect service (self-wires its match-start reset); also used by the
-- DebugToggleLights handler below.
local LightsSystem = require(script.Parent.LightsSystem)

if DebugFlags.ALL_IMPOSTORS then
	warn("[Suspect] DEBUG MODE: ALL_IMPOSTORS is ON (DebugFlags.lua) - everyone will be an impostor. Do not ship.")
end

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
	local success, reason, cooldown = PowerupService.TryUse(player, powerupId)
	Remotes.Get(Remotes.Names.PowerupUseResult):FireClient(player, powerupId, success, reason, cooldown)
	if not success then
		warn(player.Name, "failed to use", powerupId, "-", reason)
	end
end)

-- ============================================================
-- RollGacha
-- ============================================================
Remotes.Get(Remotes.Names.RollGacha).OnServerEvent:Connect(function(player)
	-- Roll decides WHICH powerup - ignore any powerupId the client sends.
	local success, resultOrError, powerupId, rollStatus = GachaService.Roll(player)
	Remotes.Get(Remotes.Names.GachaResult):FireClient(player, success, resultOrError, powerupId, rollStatus)
end)

-- ============================================================
-- UpgradePowerup - spend banked duplicates to raise a powerup's tier
-- ============================================================
Remotes.Get(Remotes.Names.UpgradePowerup).OnServerEvent:Connect(function(player, powerupId)
	if type(powerupId) ~= "string" then
		warn(player.Name, "sent an invalid UpgradePowerup id")
		return
	end
	local success, tierOrReason = PowerupOwnershipService.TryUpgrade(player, powerupId)
	Remotes.Get(Remotes.Names.UpgradeResult):FireClient(player, powerupId, success, tierOrReason)
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
-- CastVote - client sends a target player name, or nil/false to Skip
-- ============================================================
Remotes.Get(Remotes.Names.CastVote).OnServerEvent:Connect(function(player, targetName)
	local success, reason = MeetingSystem.CastVote(player, targetName)
	if not success then
		warn(player.Name, "failed to cast vote -", reason)
	end
end)

-- ============================================================
-- TaskFinished - client says its minigame window succeeded; server validates
-- the open session (see TaskManager.TryFinish) before crediting the task.
-- ============================================================
Remotes.Get(Remotes.Names.TaskFinished).OnServerEvent:Connect(function(player, taskId)
	if type(taskId) ~= "string" then
		warn(player.Name, "sent an invalid TaskFinished id")
		return
	end

	if MatchService.GetState() ~= "InProgress" or MeetingSystem.IsMeetingActive() then
		Remotes.Get(Remotes.Names.TaskResult):FireClient(player, taskId, false, "NotAllowedNow")
	else
		local ok, reason = TaskManager.TryFinish(player, taskId)
		Remotes.Get(Remotes.Names.TaskResult):FireClient(player, taskId, ok, reason)
	end
end)

-- ============================================================
-- TaskCancel - client says its task window closed WITHOUT finishing; drop the
-- open session so the station can be retriggered cleanly. Always safe - no state
-- gates; CancelSession only clears a matching open session and never touches
-- assignments or done-state.
-- ============================================================
Remotes.Get(Remotes.Names.TaskCancel).OnServerEvent:Connect(function(player, taskId)
	if type(taskId) ~= "string" then
		warn(player.Name, "sent an invalid TaskCancel id")
		return
	end
	TaskManager.CancelSession(player, taskId)
end)

-- TaskManager cannot require MeetingSystem (cycle via MatchService), so the
-- composition root wires this reaction: drop every open task session when a
-- meeting starts (players frozen at a station can't keep a window alive).
MeetingSystem.OnMeetingStart(function()
	TaskManager.ClearAllSessions()
end)

-- ============================================================
-- DebugToggleLights - test key (P) flips lights-out until the real sabotage
-- system exists. Gated server-side by DebugFlags; the client always fires it.
-- ============================================================
Remotes.Get(Remotes.Names.DebugToggleLights).OnServerEvent:Connect(function(player)
	if not DebugFlags.LIGHTS_TEST_CONTROLS then
		warn(player.Name, "tried DebugToggleLights but LIGHTS_TEST_CONTROLS is off")
		return
	end
	LightsSystem.SetLightsOut(not LightsSystem.IsLightsOut())
end)

-- ============================================================
-- Player join: set currency, then manually spawn ONLY if the round loop is in a
-- phase where a fresh character belongs. Joiners during "InProgress"/"Ended"
-- deliberately get NO character - they are spectators until the round loop
-- spawns them at the next intermission. CharacterAutoLoads is off, so no
-- character appears unless we make one here.
-- ============================================================
Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("Currency", 500)
	if DebugFlags.GRANT_ALL_POWERUPS then
		PowerupOwnershipService.DebugGrantMax(player, PowerupService.Definitions)
	end

	local state = MatchService.GetState()
	if state == "Waiting" or state == "Intermission" then
		player:LoadCharacter()
	end
end)

-- Start the round loop. This is the ONLY call site.
MatchService.StartRoundLoop()

print("[Suspect] Services initialized.")