--[[
	LoadoutService.lua
	Tracks each player's 2 EQUIPPED powerup slots for the current match.
	Equipping is validated against PowerupOwnershipService - you can only
	equip what you actually own. This is set in the lobby (via the
	SetLoadout remote) before a match starts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PowerupOwnershipService = require(ServerScriptService.Services.PowerupOwnershipService)
local Remotes = require(ReplicatedStorage.Modules.Remotes)
-- Cycle-safe: MatchService requires RoleManager/TaskManager/Remotes/DebugFlags
-- and RoleManager requires only Remotes - neither ever requires LoadoutService.
local MatchService = require(ServerScriptService.Services.MatchService)
local RoleManager = require(ServerScriptService.Services.RoleManager)

local LoadoutService = {}

local MAX_SLOTS = 2

-- player -> { powerupId, ... } staged for the NEXT match (editable at ANY time).
local pendingLoadouts = {}
-- player -> { powerupId, ... } locked in for the CURRENT match. Written ONLY at
-- match start from the pending set - nothing during a match ever changes it.
local activeLoadouts = {}

-- Returns true/false, and an error reason on failure.
function LoadoutService.SetLoadout(player, powerupIds)
	-- Editing is safe at ANY time by construction: activeLoadouts is written
	-- exclusively at MatchService.OnMatchStart from pending, so an alive player's
	-- mid-match save affects only their next match, and a countdown-phase save
	-- lands in the match about to start. No state gate is needed here at all.
	if type(powerupIds) ~= "table" or #powerupIds > MAX_SLOTS then
		return false, "InvalidSlotCount"
	end

	local seen = {}
	for _, powerupId in ipairs(powerupIds) do
		if type(powerupId) ~= "string" then
			return false, "InvalidEntry"
		end
		if seen[powerupId] then
			return false, "DuplicateEntry"
		end
		seen[powerupId] = true
		if not PowerupOwnershipService.Owns(player, powerupId) then
			return false, "NotOwned:" .. tostring(powerupId)
		end
	end

	pendingLoadouts[player] = table.clone(powerupIds)
	return true
end

function LoadoutService.GetLoadout(player)
	return activeLoadouts[player] or {}
end

function LoadoutService.GetPending(player)
	return pendingLoadouts[player] or {}
end

function LoadoutService.HasEquipped(player, powerupId)
	local loadout = activeLoadouts[player]
	if not loadout then
		return false
	end
	return table.find(loadout, powerupId) ~= nil
end

-- At match start, promote every player's pending loadout to active. This is the
-- ONLY place active loadouts are ever written - dying and editing pending
-- mid-match never touches the active set.
MatchService.OnMatchStart(function()
	for _, player in ipairs(Players:GetPlayers()) do
		activeLoadouts[player] = table.clone(pendingLoadouts[player] or {})
		Remotes.Get(Remotes.Names.LoadoutApplied):FireClient(player, activeLoadouts[player])
	end
end)

Players.PlayerRemoving:Connect(function(player)
	pendingLoadouts[player] = nil
	activeLoadouts[player] = nil
end)

return LoadoutService
