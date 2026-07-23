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

-- Main entry point: called from the RollGacha RemoteEvent handler. The roll
-- decides WHICH powerup you get (weighted by rarity); the tier/duplicate side
-- is handled by PowerupOwnershipService. Pity guarantees a Rare-or-better
-- POWERUP within PITY_THRESHOLD rolls, matching the roadmap's disclosed odds.
-- Returns (success: bool, resultOrError: string, powerupId: string?, rollStatus: "New"|"Duplicate"|nil)
function GachaService.Roll(player)
	if not CurrencyStub.Spend(player, ROLL_COST) then
		return false, "InsufficientCurrency"
	end

	pityCounter[player] = (pityCounter[player] or 0) + 1
	local forcePity = pityCounter[player] >= PITY_THRESHOLD

	-- Build the candidate pool from all powerups, excluding Commons once pity
	-- kicks in so the result is guaranteed Rare-or-better.
	local pool = {}
	local totalWeight = 0
	for id, def in pairs(PowerupService.Definitions) do
		if not (forcePity and def.rarity == "Common") then
			table.insert(pool, id)
			totalWeight += def.weight
		end
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	local pickedId = pool[#pool] -- fallback, shouldn't hit
	for _, id in ipairs(pool) do
		cumulative += PowerupService.Definitions[id].weight
		if roll <= cumulative then
			pickedId = id
			break
		end
	end

	if PowerupService.Definitions[pickedId].rarity ~= "Common" then
		pityCounter[player] = 0
	end

	local status = PowerupOwnershipService.GrantOrDuplicate(player, pickedId)

	return true, "Success", pickedId, status
end

-- One-call snapshot for the client gacha UI: cost, this player's pity progress,
-- and every powerup with its roll odds + this player's tier/duplicate progress.
-- Read-only, no side effects - safe for any client to call at any time.
function GachaService.GetCatalog(player)
	local RARITY_RANK = { Common = 1, Rare = 2, Epic = 3 }

	-- Per-powerup roll percent, straight from GetOdds so display + roll agree.
	local percentById = {}
	for _, o in ipairs(PowerupService.GetOdds()) do
		percentById[o.powerupId] = o.percent
	end

	local powerups = {}
	for id, def in pairs(PowerupService.Definitions) do
		local entry = PowerupOwnershipService.GetOwnedEntry(player, id)
		table.insert(powerups, {
			id = id,
			displayName = def.displayName,
			rarity = def.rarity,
			percent = percentById[id],
			tier = entry and entry.tier or nil,
			duplicates = entry and entry.duplicates or 0,
			duplicatesNeeded = 3,
			maxTier = 3,
		})
	end

	table.sort(powerups, function(a, b)
		local ra, rb = RARITY_RANK[a.rarity] or math.huge, RARITY_RANK[b.rarity] or math.huge
		if ra ~= rb then
			return ra < rb
		end
		return a.displayName < b.displayName
	end)

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