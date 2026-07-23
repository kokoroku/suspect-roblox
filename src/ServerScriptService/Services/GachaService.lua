--[[
	GachaService.lua
	Handles rolling for powerup variants. Odds are always computed from
	PowerupService.Definitions so the UI and the actual roll can NEVER
	drift out of sync - one source of truth for both display and outcome.
	Successful rolls grant/upgrade ownership via PowerupOwnershipService -
	rolling does NOT equip anything, players still choose their 2-slot
	loadout separately (see LoadoutService).

	NOTE: CurrencyService (spending/earning soft currency) isn't built yet -
	this stubs a GetBalance/Spend pair so GachaService can be wired up now
	and swapped to the real thing later without changing this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local PowerupService = require(script.Parent.PowerupService)
local PowerupOwnershipService = require(ServerScriptService.Services.PowerupOwnershipService)

local GachaService = {}

local ROLL_COST = 50
local PITY_THRESHOLD = 10 -- guaranteed Rare-or-better within this many rolls

-- player -> rollsSinceRare
local pityCounter = {}

-- TEMP stub - replace with real CurrencyService once built.
local CurrencyStub = {}
function CurrencyStub.GetBalance(player)
	return player:GetAttribute("Currency") or 0
end
function CurrencyStub.Spend(player, amount)
	local balance = CurrencyStub.GetBalance(player)
	if balance < amount then
		return false
	end
	player:SetAttribute("Currency", balance - amount)
	return true
end

-- Weighted random pick from a powerup's variants table.
local function rollVariant(powerupId, forceRareOrBetter)
	local odds = PowerupService.GetOdds(powerupId)

	if forceRareOrBetter then
		-- filter out Common when pity kicks in
		local filtered = {}
		for _, entry in ipairs(odds) do
			if entry.variant ~= "Common" then
				table.insert(filtered, entry)
			end
		end
		odds = filtered
	end

	local totalWeight = 0
	local def = PowerupService.Definitions[powerupId]
	for _, entry in ipairs(odds) do
		totalWeight += def.variants[entry.variant].weight
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, entry in ipairs(odds) do
		cumulative += def.variants[entry.variant].weight
		if roll <= cumulative then
			return entry.variant
		end
	end

	return odds[#odds].variant -- fallback, shouldn't hit
end

-- Main entry point: called from the RollGacha RemoteEvent handler.
-- Returns (success: bool, resultOrError: string, variant: string?, rollStatus: "New"|"Upgraded"|"Duplicate"|nil)
function GachaService.Roll(player, powerupId)
	if not PowerupService.Definitions[powerupId] then
		return false, "UnknownPowerup"
	end

	if not CurrencyStub.Spend(player, ROLL_COST) then
		return false, "InsufficientCurrency"
	end

	pityCounter[player] = (pityCounter[player] or 0) + 1
	local forcePity = pityCounter[player] >= PITY_THRESHOLD

	local variant = rollVariant(powerupId, forcePity)

	if variant ~= "Common" then
		pityCounter[player] = 0
	end

	local rollStatus = PowerupOwnershipService.GrantOrUpgrade(player, powerupId, variant)

	return true, "Success", variant, rollStatus
end

-- Used by the lobby UI to show odds + current pity progress before rolling.
function GachaService.GetDisclosure(player, powerupId)
	return {
		odds = PowerupService.GetOdds(powerupId),
		cost = ROLL_COST,
		pityRollsUsed = pityCounter[player] or 0,
		pityThreshold = PITY_THRESHOLD,
	}
end

-- One-call snapshot for the client gacha UI: cost, this player's pity progress,
-- and every powerup with its odds + which variant this player already owns.
-- Read-only, no side effects - safe for any client to call at any time.
function GachaService.GetCatalog(player)
	-- pairs order is nondeterministic - sort ids so the UI never reorders.
	local ids = {}
	for id in pairs(PowerupService.Definitions) do
		table.insert(ids, id)
	end
	table.sort(ids)

	local powerups = {}
	for _, id in ipairs(ids) do
		local def = PowerupService.Definitions[id]
		table.insert(powerups, {
			id = id,
			displayName = def.displayName,
			team = def.team,
			odds = PowerupService.GetOdds(id),
			ownedVariant = PowerupOwnershipService.GetOwnedVariant(player, id),
		})
	end

	return {
		cost = ROLL_COST,
		pityRollsUsed = pityCounter[player] or 0,
		pityThreshold = PITY_THRESHOLD,
		powerups = powerups,
	}
end

Players.PlayerRemoving:Connect(function(player)
	pityCounter[player] = nil
end)

return GachaService