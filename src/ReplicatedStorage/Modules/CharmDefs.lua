--[[
	CharmDefs.lua
	The single source of truth the Charm system interprets: every powerup ("Charm")
	keyed by its stable internal id. PowerupService resolves USE against this data
	and GachaService rolls against it - neither carries its own copy anymore.

	Two kinds of fields live here:

	1. LIVE fields, moved verbatim from PowerupService/GachaService with no value
	   changes: displayName, rarity, gachaWeight, cooldown, tiers (the per-tier
	   stat tables exactly as they were - including Seer's per-tier usesPerMatch).

	2. SCAFFOLD fields for the Séance re-theme (see docs/DESIGN.md sections 7 & 11),
	   PRESENT BUT UNUSED - nothing reads them yet, they are Phase 2 targets:
	     loadoutWeight - the Charm-grammar weight budget (DESIGN.md section 7).
	     essence       - the Essence this Charm donates when bound (DESIGN.md section 7).
	     faces         - { Crew, Vessel } role-dependent expressions (filled Phase 2).
	     omen          - the public tell an activation emits (filled Phase 2).

	No requires: this must be loadable from both server and client with no deps.
]]

local CharmDefs = {}

-- Keyed by the EXISTING powerup ids - these stay stable; only DISPLAY strings
-- change in the re-theme.
CharmDefs.Charms = {
	SpeedBoost = {
		displayName = "Speed Boost",
		rarity = "Common",
		gachaWeight = 30,
		cooldown = 20,
		tiers = {
			{ speedMultiplier = 1.15, duration = 5 },
			{ speedMultiplier = 1.25, duration = 7 },
			{ speedMultiplier = 1.35, duration = 10 },
		},
		-- Scaffold (Phase 2, unused):
		loadoutWeight = 1,
		essence = "Haste",
		faces = { Crew = nil, Vessel = nil },
		omen = nil,
	},
	Flashlight = {
		displayName = "Flashlight",
		rarity = "Common",
		gachaWeight = 30,
		cooldown = 30,
		-- fogEnd: how far the BEARER sees in the dark (client fog, applied by
		-- PowerupFX). glowRange: the head light EVERYONE sees them by.
		-- Tier 3's fogEnd equals the impostor's dark vision - full parity with an
		-- impostor's sight, bought with a loadout slot and with being visible.
		tiers = {
			{ fogEnd = 45, glowRange = 16 },
			{ fogEnd = 65, glowRange = 22 },
			{ fogEnd = 90, glowRange = 30 },
		},
		-- Scaffold (Phase 2, unused):
		loadoutWeight = 1,
		essence = "Light",
		faces = { Crew = nil, Vessel = nil },
		omen = nil,
	},
	Invisibility = {
		displayName = "Invisibility",
		rarity = "Rare",
		gachaWeight = 20,
		cooldown = 40,
		tiers = {
			{ duration = 6 },
			{ duration = 9 },
			{ duration = 12 },
		},
		-- Scaffold (Phase 2, unused):
		loadoutWeight = 2,
		essence = "Veil",
		faces = { Crew = nil, Vessel = nil },
		omen = nil,
	},
	Shapeshifter = {
		displayName = "Shapeshifter",
		rarity = "Epic",
		gachaWeight = 10,
		cooldown = 60,
		tiers = {
			{ duration = 15 },
			{ duration = 20 },
			{ duration = 25 },
		},
		-- Scaffold (Phase 2, unused):
		loadoutWeight = 3,
		essence = "Mirage",
		faces = { Crew = nil, Vessel = nil },
		omen = nil,
	},
	Seer = {
		displayName = "Seer",
		rarity = "Epic",
		gachaWeight = 10,
		cooldown = 30,
		tiers = {
			{ minAlive = 5, usesPerMatch = 1 },
			{ minAlive = 4, usesPerMatch = 1 },
			{ minAlive = 4, usesPerMatch = 2 },
		},
		-- Scaffold (Phase 2, unused):
		loadoutWeight = 3,
		essence = "Insight",
		faces = { Crew = nil, Vessel = nil },
		omen = nil,
	},
}

return CharmDefs
