--[[
	LoadoutService.lua
	Tracks each player's 2 EQUIPPED powerup slots for the current match.
	Equipping is validated against PowerupOwnershipService - you can only
	equip what you actually own. This is set in the lobby (via the
	SetLoadout remote) before a match starts.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local PowerupOwnershipService = require(ServerScriptService.Services.PowerupOwnershipService)

local LoadoutService = {}

local MAX_SLOTS = 2

-- player -> { powerupId, powerupId } (up to MAX_SLOTS entries)
local loadouts = {}

-- Returns true/false, and an error reason on failure.
function LoadoutService.SetLoadout(player, powerupIds)
	if type(powerupIds) ~= "table" or #powerupIds > MAX_SLOTS then
		return false, "InvalidSlotCount"
	end

	for _, powerupId in ipairs(powerupIds) do
		if not PowerupOwnershipService.Owns(player, powerupId) then
			return false, "NotOwned:" .. tostring(powerupId)
		end
	end

	loadouts[player] = powerupIds
	return true
end

function LoadoutService.GetLoadout(player)
	return loadouts[player] or {}
end

function LoadoutService.HasEquipped(player, powerupId)
	local loadout = loadouts[player]
	if not loadout then
		return false
	end
	return table.find(loadout, powerupId) ~= nil
end

Players.PlayerRemoving:Connect(function(player)
	loadouts[player] = nil
end)

return LoadoutService