--[[
	PowerupOwnershipService.lua
	Tracks each player's PERMANENT collection of unlocked powerups - what
	they own, separate from what they have equipped for the current match.
	Gacha rolls call GrantOrUpgrade here, not PowerupService directly.

	Ownership model: one entry per powerup ID, tracking the BEST variant
	owned. Rolling a variant you already have at equal-or-lower rarity
	does nothing; rolling higher upgrades it. Keeps inventory simple -
	no stacking duplicate items to manage.
]]

local Players = game:GetService("Players")

local PowerupOwnershipService = {}

local RARITY_RANK = { Common = 1, Rare = 2, Epic = 3 }

-- player -> { [powerupId] = "Common" | "Rare" | "Epic" }
local owned = {}

function PowerupOwnershipService.GrantOrUpgrade(player, powerupId, variant)
	owned[player] = owned[player] or {}
	local current = owned[player][powerupId]

	if not current or RARITY_RANK[variant] > RARITY_RANK[current] then
		owned[player][powerupId] = variant
		return true, variant -- new or upgraded
	end

	return false, current -- no change, already own this or better
end

function PowerupOwnershipService.GetOwnedVariant(player, powerupId)
	local playerOwned = owned[player]
	return playerOwned and playerOwned[powerupId] or nil
end

function PowerupOwnershipService.GetAllOwned(player)
	return owned[player] or {}
end

function PowerupOwnershipService.Owns(player, powerupId)
	return PowerupOwnershipService.GetOwnedVariant(player, powerupId) ~= nil
end

Players.PlayerRemoving:Connect(function(player)
	owned[player] = nil
end)

return PowerupOwnershipService