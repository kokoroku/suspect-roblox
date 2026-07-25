--[[
	GachaService.lua
	Handles rolling for powerup variants. Weights, rarity classes and catalog
	data are read from the shared CharmDefs module (the single source of truth),
	and odds come from PowerupService.GetOdds which reads the same data - so the
	UI and the actual roll can NEVER drift out of sync.
	Successful rolls grant/upgrade ownership via PowerupOwnershipService -
	rolling does NOT equip anything, players still choose their 2-slot
	loadout separately (see LoadoutService).

	Currency and gacha pity are now PERSISTED: both live in the player's
	PlayerDataService session. The local Currency helper reads/writes data.currency
	(keeping the player's Currency Attribute as a UI mirror), and pity reads/writes
	data.pity - each marking the session dirty. A dedicated earning/CurrencyService
	is still future work, but the balance no longer resets per server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local CharmDefs = require(ReplicatedStorage.Modules.CharmDefs)
local PowerupService = require(script.Parent.PowerupService)
local PowerupOwnershipService = require(ServerScriptService.Services.PowerupOwnershipService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)

local GachaService = {}

local ROLL_COST = 50
local PITY_THRESHOLD = 10 -- guaranteed Rare-or-better within this many rolls

-- Currency now lives in PlayerDataService (data.currency); the player Attribute
-- is a read-only MIRROR the existing UI reads. Spend updates BOTH and marks the
-- session dirty. GetBalance reads the persisted source of truth.
local Currency = {}
function Currency.GetBalance(player)
	local data = PlayerDataService.Get(player)
	return data and data.currency or 0
end
function Currency.Spend(player, amount)
	local data = PlayerDataService.Get(player)
	if not data or data.currency < amount then
		return false
	end
	data.currency = data.currency - amount
	player:SetAttribute("Currency", data.currency) -- keep the UI mirror in sync
	PlayerDataService.MarkDirty(player)
	return true
end

-- Main entry point: called from the RollGacha RemoteEvent handler. The roll
-- decides WHICH powerup you get (weighted by rarity); the tier/duplicate side
-- is handled by PowerupOwnershipService. Pity guarantees a Rare-or-better
-- POWERUP within PITY_THRESHOLD rolls, matching the roadmap's disclosed odds.
-- Returns (success: bool, resultOrError: string, powerupId: string?, rollStatus: "New"|"Duplicate"|nil)
function GachaService.Roll(player)
	-- Join-order safety: never roll against not-yet-loaded (default) data - it
	-- would spend/persist onto a throwaway session.
	if not PlayerDataService.IsLoaded(player) then
		return false, "StillLoading"
	end

	if not Currency.Spend(player, ROLL_COST) then
		return false, "InsufficientCurrency"
	end

	local data = PlayerDataService.Get(player)
	data.pity = (data.pity or 0) + 1
	PlayerDataService.MarkDirty(player)
	local forcePity = data.pity >= PITY_THRESHOLD

	-- Build the candidate pool from all powerups, excluding Commons once pity
	-- kicks in so the result is guaranteed Rare-or-better.
	local pool = {}
	local totalWeight = 0
	for id, def in pairs(CharmDefs.Charms) do
		if not (forcePity and def.rarity == "Common") then
			table.insert(pool, id)
			totalWeight += def.gachaWeight
		end
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	local pickedId = pool[#pool] -- fallback, shouldn't hit
	for _, id in ipairs(pool) do
		cumulative += CharmDefs.Charms[id].gachaWeight
		if roll <= cumulative then
			pickedId = id
			break
		end
	end

	if CharmDefs.Charms[pickedId].rarity ~= "Common" then
		data.pity = 0
		PlayerDataService.MarkDirty(player)
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
	for id, def in pairs(CharmDefs.Charms) do
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

	-- Read-only snapshot: tolerate a not-yet-loaded session (pity reads 0), so the
	-- catalog can still populate the UI while data is in flight.
	local data = PlayerDataService.Get(player)

	return {
		cost = ROLL_COST,
		pityRollsUsed = (data and data.pity) or 0,
		pityThreshold = PITY_THRESHOLD,
		powerups = powerups,
	}
end

-- No per-player cleanup here anymore: currency and pity live in the player's
-- PlayerDataService session, which that service clears on PlayerRemoving.

return GachaService