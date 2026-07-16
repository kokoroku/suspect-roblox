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

local PowerupOwnershipService = require(ServerScriptService.Services.PowerupOwnershipService)
local LoadoutService = require(ServerScriptService.Services.LoadoutService)

local PowerupService = {}

-- ============================================================
-- Powerup + variant definitions
-- Add new powerups by adding a new top-level entry here.
-- ============================================================
PowerupService.Definitions = {
	SpeedBoost = {
		displayName = "Speed Boost",
		team = "Crew",
		variants = {
			Common = { speedMultiplier = 1.15, duration = 5, weight = 60 },
			Rare   = { speedMultiplier = 1.25, duration = 7, weight = 30 },
			Epic   = { speedMultiplier = 1.35, duration = 10, weight = 10 },
		},
	},
	Decoy = {
		displayName = "Decoy",
		team = "Crew",
		variants = {
			Common = { lifetime = 15, weight = 60 },
			Rare   = { lifetime = 25, weight = 30 },
			Epic   = { lifetime = 40, weight = 10 }, -- decoy also does a fake task animation
		},
	},
	VisionPulse = {
		displayName = "Vision Pulse",
		team = "Impostor",
		variants = {
			Common = { radius = 20, duration = 2, weight = 60 },
			Rare   = { radius = 30, duration = 3, weight = 30 },
			Epic   = { radius = 40, duration = 4, weight = 10 },
		},
	},
	VentLock = {
		displayName = "Vent Lock",
		team = "Crew",
		variants = {
			Common = { lockDuration = 8, weight = 60 },
			Rare   = { lockDuration = 14, weight = 30 },
			Epic   = { lockDuration = 20, weight = 10 },
		},
	},
}

local BASE_COOLDOWN_SECONDS = 20

-- player -> { [powerupId] = cooldownUntil }
local cooldowns = {}

-- Returns the odds table for a powerup, e.g. for gacha UI disclosure.
-- { {variant="Common", percent=60}, ... }
function PowerupService.GetOdds(powerupId)
	local def = PowerupService.Definitions[powerupId]
	if not def then
		return nil
	end

	local totalWeight = 0
	for _, v in pairs(def.variants) do
		totalWeight += v.weight
	end

	local odds = {}
	for name, v in pairs(def.variants) do
		table.insert(odds, {
			variant = name,
			percent = math.floor((v.weight / totalWeight) * 1000 + 0.5) / 10, -- one decimal
		})
	end
	return odds
end

-- Server-side handler for the UsePowerup RemoteEvent.
-- Returns true/false, and a reason string on failure.
function PowerupService.TryUse(player, powerupId)
	if not LoadoutService.HasEquipped(player, powerupId) then
		return false, "NotEquipped"
	end

	local variant = PowerupOwnershipService.GetOwnedVariant(player, powerupId)
	if not variant then
		return false, "NotOwned" -- shouldn't happen if equipped, but stay defensive
	end

	local playerCooldowns = cooldowns[player] or {}
	cooldowns[player] = playerCooldowns

	if os.clock() < (playerCooldowns[powerupId] or 0) then
		return false, "OnCooldown"
	end

	local def = PowerupService.Definitions[powerupId]
	local stats = def.variants[variant]

	-- Dispatch effect resolution - keep each effect's logic isolated so this
	-- function doesn't turn into a giant if/else as more powerups are added.
	local effectHandlers = {
		SpeedBoost = function()
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not humanoid then return end
			local originalSpeed = humanoid.WalkSpeed
			humanoid.WalkSpeed = originalSpeed * stats.speedMultiplier
			task.delay(stats.duration, function()
				if humanoid and humanoid.Parent then
					humanoid.WalkSpeed = originalSpeed
				end
			end)
		end,
		-- Decoy, VisionPulse, VentLock handlers go here as they're implemented
	}

	local handler = effectHandlers[powerupId]
	if handler then
		handler()
	end

	playerCooldowns[powerupId] = os.clock() + BASE_COOLDOWN_SECONDS
	return true
end

Players.PlayerRemoving:Connect(function(player)
	cooldowns[player] = nil
end)

return PowerupService