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
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)
local Remotes = require(ReplicatedStorage.Modules.Remotes)
-- Cycle-safe: CharmDefs is pure data with no requires of its own.
local CharmDefs = require(ReplicatedStorage.Modules.CharmDefs)
-- Cycle-safe: MatchService requires RoleManager/TaskManager/Remotes/DebugFlags
-- and RoleManager requires only Remotes - neither ever requires LoadoutService.
local MatchService = require(ServerScriptService.Services.MatchService)
local RoleManager = require(ServerScriptService.Services.RoleManager)
-- Cycle-safe: DebugFlags is a leaf - a table of booleans with no requires at all.
local DebugFlags = require(ServerScriptService.Services.DebugFlags)

local LoadoutService = {}

local MAX_SLOTS = 2

-- player -> { powerupId, ... } staged for the NEXT match (editable at ANY time).
local pendingLoadouts = {}
-- player -> { powerupId, ... } locked in for the CURRENT match. Written ONLY at
-- match start from the pending set - nothing during a match ever changes it.
local activeLoadouts = {}

-- Returns true/false, and an error reason on failure.
function LoadoutService.SetLoadout(player, powerupIds)
	-- Join-order safety: ownership is validated below against a cache that is
	-- empty until the player's data loads, so a save that raced the load would
	-- wrongly report NotOwned. Fail with a clear reason instead.
	if not PlayerDataService.IsLoaded(player) then
		return false, "StillLoading"
	end

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
		-- Checked BEFORE ownership so a player who owns a retired Charm is told the
		-- truth ("Retired") rather than the misleading "NotOwned".
		local def = CharmDefs.Charms[powerupId]
		if def and def.enabled == false then
			return false, "Retired"
		end
		if not PowerupOwnershipService.Owns(player, powerupId) then
			return false, "NotOwned:" .. tostring(powerupId)
		end
	end

	-- ============================================================
	-- THE WEIGHT BUDGET (docs/DESIGN.md sections 7 and 9). Common 1 / Rare 2 /
	-- Epic 3, cap 4 across the two slots - so a double-Epic loadout is impossible
	-- BY CONSTRUCTION, not by tuning the Charms down. This is the law that lets
	-- Charms be strong: progression buys expression, not oppression. In Phase 4 a
	-- Binding adds +1 to its Core's weight and this same sum keeps holding.
	--
	-- Checked AFTER every per-entry test above, so a player is always told the
	-- most specific truth first (Retired / NotOwned) and only hears about the
	-- budget once the loadout is otherwise legal.
	-- ============================================================
	local totalWeight = 0
	for _, powerupId in ipairs(powerupIds) do
		local def = CharmDefs.Charms[powerupId]
		totalWeight += (def and def.loadoutWeight) or 0
	end
	if totalWeight > CharmDefs.LOADOUT_WEIGHT_CAP then
		return false, "OverWeight"
	end

	pendingLoadouts[player] = table.clone(powerupIds)

	-- ============================================================
	-- DEBUG ONLY - LIVE_LOADOUT (DebugFlags). Verify sessions need to cycle
	-- through Charms without restarting a round between each, so this promotes the
	-- save straight onto the ACTIVE set and tells the client, which re-renders its
	-- slots through the existing LoadoutApplied listener - no client change.
	--
	-- Placed HERE, after every validation above and after pending is staged, so
	-- the flag can only ever ADD an effect. It cannot skip ownership, slot count,
	-- duplicates or the weight budget - a flag that masked a validation bug would
	-- make the thing it exists to test untrustworthy.
	--
	-- A Charm that is mid-effect when swapped out is deliberately NOT cancelled.
	-- Its effect ends through its own paths (duration expiry, meeting, death,
	-- match start) exactly as it would have; only a FUTURE TryUse reads the new
	-- active set. Cancelling here would mean reaching into PowerupService's
	-- registry from this service, which is both a require cycle and a second
	-- owner of effect lifetime.
	--
	-- With the flag false this whole block is skipped and the path above is
	-- byte-identical to today.
	-- ============================================================
	if DebugFlags.LIVE_LOADOUT then
		activeLoadouts[player] = table.clone(powerupIds)
		Remotes.Get(Remotes.Names.LoadoutApplied):FireClient(player, activeLoadouts[player])
	end

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
		-- A Charm retired since the player last saved is dropped HERE, at the
		-- promotion, and nowhere else. No mid-match surgery, and no rewriting
		-- anyone's saved data: their pending set and the ownership behind it are
		-- untouched, so the Charm simply stops arriving. Un-retiring it later needs
		-- no migration - the next promotion just lets it through again.
		--
		-- THE WEIGHT CAP IS DELIBERATELY NOT APPLIED HERE. A pending loadout saved
		-- before the cap existed (or before a Charm's weight changed) is
		-- GRANDFATHERED: it keeps promoting and keeps playing until its owner next
		-- tries to save, and that save is what fails with "OverWeight". Same
		-- principle as the retirement rule above - no retroactive surgery on data a
		-- player saved legally, and nobody gets silently disarmed at a match start
		-- they were not present for.
		local promoted = {}
		for _, powerupId in ipairs(pendingLoadouts[player] or {}) do
			local def = CharmDefs.Charms[powerupId]
			if not def or def.enabled ~= false then
				table.insert(promoted, powerupId)
			end
		end
		activeLoadouts[player] = promoted
		Remotes.Get(Remotes.Names.LoadoutApplied):FireClient(player, activeLoadouts[player])
	end
end)

Players.PlayerRemoving:Connect(function(player)
	pendingLoadouts[player] = nil
	activeLoadouts[player] = nil
end)

return LoadoutService
