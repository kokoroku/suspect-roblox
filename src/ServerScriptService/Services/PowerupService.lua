--[[
	PowerupService.lua
	Defines every powerup as a base ability with rarity variants.
	The client only ever SENDS "I want to use powerup X" - all stats,
	cooldowns, and effects are resolved here on the server.

	Design intent: rarity changes DEGREE (duration/strength), never
	changes WHETHER a player can act. This keeps the gacha a flex/collection
	loop rather than a true pay-to-win lever, and keeps a Common-tier
	powerup viable in skilled hands.
]]

local Players = game:GetService("Players")

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

-- player -> { [powerupId] = { variant = "Common", cooldownUntil = os.clock() } }
local inventory = {}

local BASE_COOLDOWN_SECONDS = 20

function PowerupService.GrantPowerup(player, powerupId, variant)
	local def = PowerupService.Definitions[powerupId]
	if not def or not def.variants[variant] then
		warn("Unknown powerup/variant:", powerupId, variant)
		return false
	end

	inventory[player] = inventory[player] or {}
	inventory[player][powerupId] = { variant = variant, cooldownUntil = 0 }
	return true
end

-- Returns the odds table for a powerup, e.g. for gacha UI disclosure.
-- { {variant="Common", weight=60, percent=60}, ... }
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
-- Returns true/false so the calling script can decide what to tell the client.
function PowerupService.TryUse(player, powerupId)
	local playerInv = inventory[player]
	local entry = playerInv and playerInv[powerupId]
	if not entry then
		return false, "NotOwned"
	end

	if os.clock() < entry.cooldownUntil then
		return false, "OnCooldown"
	end

	local def = PowerupService.Definitions[powerupId]
	local stats = def.variants[entry.variant]

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

	entry.cooldownUntil = os.clock() + BASE_COOLDOWN_SECONDS
	return true
end

Players.PlayerRemoving:Connect(function(player)
	inventory[player] = nil
end)

return PowerupService
