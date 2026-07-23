--[[
	PowerupService.lua
	Defines every powerup, its rarity variants, and resolves USE of a
	powerup during a match. Ownership (what you've unlocked) lives in
	PowerupOwnershipService; equipped state (your 2 active slots) lives
	in LoadoutService. This file only cares about: is it equipped, is it
	off cooldown, and what does using it actually do.

	Design intent: rarity changes DEGREE (duration/strength), never
	changes WHETHER a player can act. This keeps the gacha a flex/collection
	loop rather than a true pay-to-win lever, and keeps a Common-tier
	loadout viable in skilled hands.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local PowerupOwnershipService = require(ServerScriptService.Services.PowerupOwnershipService)
local LoadoutService = require(ServerScriptService.Services.LoadoutService)
-- Cycle-safe: MeetingSystem requires only RoleManager/TaskManager/Remotes and
-- never requires PowerupService - which is exactly why it exposes an
-- OnMeetingStart hook instead of calling into this module directly.
local MeetingSystem = require(ServerScriptService.Services.MeetingSystem)
-- Cycle audit: PowerupService may require all four of these because NONE of them
-- require PowerupService (or LoadoutService / PowerupOwnershipService) - every
-- reaction flows BACK through hooks only (OnMatchStart / OnKillPerformed /
-- OnLightsChanged / OnAliveChanged / OnMeetingStart), never a direct call in.
local MatchService = require(ServerScriptService.Services.MatchService)
local KillSystem = require(ServerScriptService.Services.KillSystem)
local LightsSystem = require(ServerScriptService.Services.LightsSystem)
local RoleManager = require(ServerScriptService.Services.RoleManager)

local PowerupService = {}

-- ============================================================
-- Powerup + variant definitions
-- Add new powerups by adding a new top-level entry here.
-- ============================================================
-- New shape per entry: displayName, rarity, weight (gacha roll weight),
-- cooldown (seconds), tiers = array [1..3] of stat tables.
PowerupService.Definitions = {
	SpeedBoost = {
		displayName = "Speed Boost",
		rarity = "Common",
		weight = 30,
		cooldown = 20,
		tiers = {
			{ speedMultiplier = 1.15, duration = 5 },
			{ speedMultiplier = 1.25, duration = 7 },
			{ speedMultiplier = 1.35, duration = 10 },
		},
	},
	Flashlight = {
		displayName = "Flashlight",
		rarity = "Common",
		weight = 30,
		cooldown = 30,
		tiers = {
			{ range = 20 },
			{ range = 30 },
			{ range = 40 },
		},
	},
	Invisibility = {
		displayName = "Invisibility",
		rarity = "Rare",
		weight = 20,
		cooldown = 40,
		tiers = {
			{ duration = 6 },
			{ duration = 9 },
			{ duration = 12 },
		},
	},
	Shapeshifter = {
		displayName = "Shapeshifter",
		rarity = "Epic",
		weight = 10,
		cooldown = 60,
		tiers = {
			{ duration = 15 },
			{ duration = 20 },
			{ duration = 25 },
		},
	},
	Seer = {
		displayName = "Seer",
		rarity = "Epic",
		weight = 10,
		cooldown = 30,
		tiers = {
			{ minAlive = 5, usesPerMatch = 1 },
			{ minAlive = 4, usesPerMatch = 1 },
			{ minAlive = 4, usesPerMatch = 2 },
		},
	},
}

local RARITY_RANK = { Common = 1, Rare = 2, Epic = 3 }

-- player -> { [powerupId] = cooldownUntil }
local cooldowns = {}

-- ============================================================
-- Generic active-effect registry (replaces the SpeedBoost-only table). Each
-- activeEffects[player][powerupId] = entry, where an entry carries whatever the
-- effect needs plus entry.cancel() which fully reverts it. Timed effects use
-- the entry-identity token pattern: a pending expiry only acts while
-- activeEffects[player][powerupId] is STILL that same entry table.
-- ============================================================
local activeEffects = {}

-- player -> { [powerupId] = usesRemainingThisMatch } (only for powerups whose
-- tier stats declare usesPerMatch; lazily initialized in TryUse).
local usesLeft = {}

local TARGET_RANGE = 7 -- matches KillSystem's KILL_RANGE on purpose

local function startEffect(player, powerupId, entry)
	activeEffects[player] = activeEffects[player] or {}
	activeEffects[player][powerupId] = entry
end

-- Calls entry.cancel exactly once, then clears the slot. Clearing first also
-- makes any still-pending expiry timer for this entry no-op.
local function cancelEffect(player, powerupId)
	local playerEffects = activeEffects[player]
	local entry = playerEffects and playerEffects[powerupId]
	if not entry then
		return
	end
	playerEffects[powerupId] = nil
	if entry.cancel then
		entry.cancel()
	end
end

local function cancelAllEffects(player)
	local playerEffects = activeEffects[player]
	if not playerEffects then
		return
	end
	-- Snapshot keys first - cancelEffect mutates the table.
	local ids = {}
	for powerupId in pairs(playerEffects) do
		table.insert(ids, powerupId)
	end
	for _, powerupId in ipairs(ids) do
		cancelEffect(player, powerupId)
	end
end

-- Nearest OTHER alive player within range (HumanoidRootPart distance, the same
-- approach KillSystem uses). Returns the Player, or nil if none in range.
local function findNearestOtherAlive(player, range)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local nearest, nearestDist = nil, range
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player and RoleManager.IsAlive(other) then
			local otherRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local dist = (otherRoot.Position - root.Position).Magnitude
				if dist <= nearestDist then
					nearest, nearestDist = other, dist
				end
			end
		end
	end
	return nearest
end

-- Returns the whole gacha odds table (one entry per powerup): the chance of
-- rolling each powerup, sorted by rarity rank then descending percent.
-- { {powerupId, displayName, rarity, percent}, ... }
function PowerupService.GetOdds()
	local totalWeight = 0
	for _, def in pairs(PowerupService.Definitions) do
		totalWeight += def.weight
	end

	local odds = {}
	for id, def in pairs(PowerupService.Definitions) do
		table.insert(odds, {
			powerupId = id,
			displayName = def.displayName,
			rarity = def.rarity,
			percent = math.floor((def.weight / totalWeight) * 1000 + 0.5) / 10, -- one decimal
		})
	end

	table.sort(odds, function(a, b)
		local ra, rb = RARITY_RANK[a.rarity] or math.huge, RARITY_RANK[b.rarity] or math.huge
		if ra ~= rb then
			return ra < rb
		end
		return a.percent > b.percent
	end)

	return odds
end

-- ============================================================
-- Effect handlers. Each takes (player, stats) and returns true on success, or
-- (false, reason) to fail the use BEFORE any state (cooldown/uses) is committed.
-- Timed effects register onto the active-effect registry and self-expire via
-- the entry-identity token pattern.
-- ============================================================
local effectHandlers = {
	SpeedBoost = function(player, stats)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return false, "NoCharacter"
		end

		local entry = { originalSpeed = humanoid.WalkSpeed }
		entry.cancel = function()
			-- Re-fetch: the character may have been replaced since the boost
			-- started, so a stale reference could write to a dead rig.
			local char = player.Character
			local h = char and char:FindFirstChildOfClass("Humanoid")
			if h then
				h.WalkSpeed = entry.originalSpeed
			end
		end
		startEffect(player, "SpeedBoost", entry)
		humanoid.WalkSpeed = entry.originalSpeed * stats.speedMultiplier

		task.delay(stats.duration, function()
			if activeEffects[player] and activeEffects[player]["SpeedBoost"] == entry then
				cancelEffect(player, "SpeedBoost")
			end
		end)
		return true
	end,

	Invisibility = function(player, stats)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not humanoid then
			return false, "NoCharacter"
		end

		local entry = {
			originalTransparency = {}, -- BasePart -> original Transparency
			originalDisplayDistanceType = humanoid.DisplayDistanceType,
		}
		-- Every BasePart except the root (accessories' Handles included).
		for _, desc in ipairs(character:GetDescendants()) do
			if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
				entry.originalTransparency[desc] = desc.Transparency
				desc.Transparency = 1
			end
		end
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

		entry.cancel = function()
			for part, transparency in pairs(entry.originalTransparency) do
				if part.Parent then
					part.Transparency = transparency
				end
			end
			local char = player.Character
			local h = char and char:FindFirstChildOfClass("Humanoid")
			if h then
				h.DisplayDistanceType = entry.originalDisplayDistanceType
			end
			Remotes.Get(Remotes.Names.PowerupEffect):FireClient(player, "Invisibility", "End", {})
		end
		startEffect(player, "Invisibility", entry)

		Remotes.Get(Remotes.Names.PowerupEffect):FireClient(player, "Invisibility", "Start", {})

		task.delay(stats.duration, function()
			if activeEffects[player] and activeEffects[player]["Invisibility"] == entry then
				cancelEffect(player, "Invisibility")
			end
		end)
		return true
	end,

	-- Design note: Player.Name is NEVER touched, so votes, reports, Seer results
	-- and corpse identity always tell the truth - the disguise is purely
	-- audiovisual (appearance + overhead DisplayName). Reverting on death happens
	-- BEFORE ragdoll conversion because RoleManager.SetAlive fires OnAliveChanged
	-- first (see the OnAliveChanged wiring below).
	Shapeshifter = function(player, stats)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return false, "NoCharacter"
		end

		local target = findNearestOtherAlive(player, TARGET_RANGE)
		if not target then
			return false, "NoTargetNearby"
		end
		local targetCharacter = target.Character
		local targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
		if not targetHumanoid then
			return false, "NoTargetNearby"
		end

		local entry = { originalDisplayName = humanoid.DisplayName }
		pcall(function()
			entry.originalDescription = humanoid:GetAppliedDescription()
		end)

		pcall(function()
			humanoid:ApplyDescription(targetHumanoid:GetAppliedDescription())
		end)
		humanoid.DisplayName = targetHumanoid.DisplayName

		entry.cancel = function()
			local char = player.Character
			local h = char and char:FindFirstChildOfClass("Humanoid")
			if h then
				if entry.originalDescription then
					pcall(function()
						h:ApplyDescription(entry.originalDescription)
					end)
				end
				h.DisplayName = entry.originalDisplayName
			end
		end
		startEffect(player, "Shapeshifter", entry)

		task.delay(stats.duration, function()
			if activeEffects[player] and activeEffects[player]["Shapeshifter"] == entry then
				cancelEffect(player, "Shapeshifter")
			end
		end)
		return true
	end,

	Seer = function(player, stats)
		local aliveCount = 0
		for _, other in ipairs(Players:GetPlayers()) do
			if RoleManager.IsAlive(other) then
				aliveCount += 1
			end
		end
		if aliveCount < stats.minAlive then
			return false, "MinAliveNotMet"
		end

		local target = findNearestOtherAlive(player, TARGET_RANGE)
		if not target then
			return false, "NoTargetNearby"
		end

		-- Instant - no registry entry, no cancel. Reveal goes to the USER only.
		Remotes.Get(Remotes.Names.SeerResult):FireClient(player, target.Name, RoleManager.GetRole(target))
		return true
	end,

	Flashlight = function(player, stats)
		if not LightsSystem.IsLightsOut() then
			return false, "LightsAreOn"
		end

		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		if not head then
			return false, "NoCharacter"
		end

		-- A server-side light is deliberately visible to EVERYONE (impostor
		-- included) - using it is a beacon.
		local light = Instance.new("SpotLight")
		light.Brightness = 5
		light.Angle = 60
		light.Range = stats.range
		light.Face = Enum.NormalId.Front
		light.Parent = head

		local entry = { light = light }
		entry.cancel = function()
			if light then
				light:Destroy()
			end
			Remotes.Get(Remotes.Names.PowerupEffect):FireClient(player, "Flashlight", "End", {})
		end
		startEffect(player, "Flashlight", entry)

		Remotes.Get(Remotes.Names.PowerupEffect):FireClient(player, "Flashlight", "Start", { range = stats.range })
		-- No duration - it ends when the lights come back on (OnLightsChanged) or
		-- on meeting/death/match reset.
		return true
	end,
}

-- Server-side handler for the UsePowerup RemoteEvent.
-- Returns (true, nil, cooldownSeconds) on success - the cooldown is for the
-- client HUD - or (false, reason) on failure.
function PowerupService.TryUse(player, powerupId)
	if MatchService.GetState() ~= "InProgress" then
		return false, "MatchNotInProgress"
	end

	if MeetingSystem.IsMeetingActive() then
		return false, "MeetingActive"
	end

	if not LoadoutService.HasEquipped(player, powerupId) then
		return false, "NotEquipped"
	end

	local tier = PowerupOwnershipService.GetOwnedTier(player, powerupId)
	if not tier then
		return false, "NotOwned" -- shouldn't happen if equipped, but stay defensive
	end

	if activeEffects[player] and activeEffects[player][powerupId] then
		return false, "AlreadyActive"
	end

	local def = PowerupService.Definitions[powerupId]
	local stats = def.tiers[tier]

	-- Per-match uses: only powerups whose tier stats declare usesPerMatch are
	-- limited. Lazily seed the counter, then gate.
	local playerUses = usesLeft[player] or {}
	usesLeft[player] = playerUses
	if stats.usesPerMatch ~= nil then
		if playerUses[powerupId] == nil then
			playerUses[powerupId] = stats.usesPerMatch
		end
		if playerUses[powerupId] <= 0 then
			return false, "NoUsesLeft"
		end
	end

	local playerCooldowns = cooldowns[player] or {}
	cooldowns[player] = playerCooldowns
	if os.clock() < (playerCooldowns[powerupId] or 0) then
		return false, "OnCooldown"
	end

	local handler = effectHandlers[powerupId]
	if not handler then
		return false, "NotImplementedYet"
	end

	-- The handler may itself reject (e.g. NoTargetNearby, LightsAreOn) BEFORE any
	-- state is committed.
	local ok, reason = handler(player, stats)
	if not ok then
		return false, reason
	end

	-- Commit only on success: set cooldown + spend a use.
	playerCooldowns[powerupId] = os.clock() + def.cooldown
	if stats.usesPerMatch ~= nil then
		playerUses[powerupId] = playerUses[powerupId] - 1
	end

	return true, nil, def.cooldown
end

-- ============================================================
-- Cancellation wiring. Every reaction flows in through a hook - see the cycle
-- audit at the top of the file.
-- ============================================================

-- A meeting freezes and gathers everyone, so no active effect should carry
-- across it (also snapshots un-boosted speeds for the freeze).
MeetingSystem.OnMeetingStart(function()
	for _, player in ipairs(Players:GetPlayers()) do
		cancelAllEffects(player)
	end
end)

-- Death ends every effect on that player (their Shapeshifter disguise reverts
-- here, BEFORE ragdoll conversion, because SetAlive fires OnAliveChanged first).
RoleManager.OnAliveChanged(function(player, alive)
	if alive == false then
		cancelAllEffects(player)
	end
end)

-- Landing a kill reveals you: drop Invisibility. Other effects survive a kill.
KillSystem.OnKillPerformed(function(killer)
	cancelEffect(killer, "Invisibility")
end)

-- When the lights come back on, every active Flashlight switches off (it has no
-- duration of its own - it lives exactly as long as the darkness).
LightsSystem.OnLightsChanged(function(state)
	if state == false then
		for _, player in ipairs(Players:GetPlayers()) do
			if activeEffects[player] and activeEffects[player]["Flashlight"] then
				cancelEffect(player, "Flashlight")
			end
		end
	end
end)

-- Fresh match: clear every player's effects, cooldowns and per-match uses.
MatchService.OnMatchStart(function()
	for _, player in ipairs(Players:GetPlayers()) do
		cancelAllEffects(player)
		cooldowns[player] = nil
		usesLeft[player] = nil
	end
end)

Players.PlayerRemoving:Connect(function(player)
	cooldowns[player] = nil
	activeEffects[player] = nil
	usesLeft[player] = nil
end)

return PowerupService