--[[
	PowerupOwnershipService.lua
	Tracks each player's PERMANENT collection of unlocked powerups - what
	they own, separate from what they have equipped for the current match.
	Gacha rolls call GrantOrDuplicate here, not PowerupService directly.

	Ownership model: one entry per powerup ID, tracking its unlocked TIER
	(1..MAX_TIER) plus a bank of DUPLICATES built up from re-rolling something
	you already own. Rolling never upgrades any more - it only banks duplicates;
	spending DUPLICATES_PER_UPGRADE of them raises the tier (see TryUpgrade).
]]

local Players = game:GetService("Players")

local PowerupOwnershipService = {}

local MAX_TIER = 3
local DUPLICATES_PER_UPGRADE = 3

-- player -> { [powerupId] = { tier = 1..MAX_TIER, duplicates = n } }
local owned = {}

-- Rolling result. Returns (status, ...):
--   "New"       - the player did not own this powerup; now owns it at tier 1
--   "Duplicate" - already owned; a duplicate was banked. 2nd return = new count
-- Renamed from GrantOrUpgrade because rolling can no longer upgrade (that
-- superseded the old New/Upgraded/Duplicate contract).
function PowerupOwnershipService.GrantOrDuplicate(player, powerupId)
	owned[player] = owned[player] or {}
	local entry = owned[player][powerupId]

	if not entry then
		owned[player][powerupId] = { tier = 1, duplicates = 0 }
		return "New"
	end

	entry.duplicates += 1
	return "Duplicate", entry.duplicates
end

-- The skill-smith operation: spend DUPLICATES_PER_UPGRADE duplicates to raise a
-- powerup's tier by one. The smith NPC/space comes later - the economy works
-- now. Returns (false, reason) or (true, newTier).
function PowerupOwnershipService.TryUpgrade(player, powerupId)
	local entry = owned[player] and owned[player][powerupId]
	if not entry then
		return false, "NotOwned"
	end
	if entry.tier >= MAX_TIER then
		return false, "MaxTier"
	end
	if entry.duplicates < DUPLICATES_PER_UPGRADE then
		return false, "NotEnoughDuplicates"
	end

	entry.duplicates -= DUPLICATES_PER_UPGRADE
	entry.tier += 1
	return true, entry.tier
end

function PowerupOwnershipService.GetOwnedTier(player, powerupId)
	local entry = owned[player] and owned[player][powerupId]
	return entry and entry.tier or nil
end

function PowerupOwnershipService.GetOwnedEntry(player, powerupId)
	return owned[player] and owned[player][powerupId] or nil
end

function PowerupOwnershipService.GetAllOwned(player)
	return owned[player] or {}
end

function PowerupOwnershipService.Owns(player, powerupId)
	return PowerupOwnershipService.GetOwnedEntry(player, powerupId) ~= nil
end

-- Test-only: unlock every powerup at max tier. Called by Bootstrap under
-- DebugFlags.GRANT_ALL_POWERUPS. Takes the definitions table as a parameter
-- because requiring PowerupService here would be a cycle (it requires us).
function PowerupOwnershipService.DebugGrantMax(player, definitions)
	owned[player] = owned[player] or {}
	for id in pairs(definitions) do
		owned[player][id] = { tier = MAX_TIER, duplicates = 0 }
	end
end

Players.PlayerRemoving:Connect(function(player)
	owned[player] = nil
end)

return PowerupOwnershipService
