--[[
	CharmDefs.lua
	The single source of truth the Charm system interprets: every powerup ("Charm")
	keyed by its stable internal id. PowerupService resolves USE against this data
	and GachaService rolls against it - neither carries its own copy anymore.

	Field groups:

	1. LIVE fields: displayName (re-themed strings only - the ids NEVER change),
	   rarity, gachaWeight, cooldown, tiers (the per-tier stat tables). `cooldown`
	   is the Charm's pacing FLOOR - a face may override it (see below).

	2. faces = { Crew, Vessel } - the dual-face law (docs/DESIGN.md section 7).
	   Loadouts lock BEFORE roles are assigned, so every Charm must be worth a slot
	   to either role; PowerupService picks the face at USE time from the player's
	   role. For each Charm, ONE face is the behavior that already shipped and reads
	   the same per-tier table as `tiers` (wired at the bottom of this file so the
	   two can never drift); the OTHER face's tuning sits alongside it as initial
	   values, playtest-tuned later.
	   All four enabled Charms are dual-faced for real - PowerupService implements
	   both faces of each, no aliases left.
	   A face may also carry its own RESOURCE values, which is how two faces of one
	   Charm can be paced by different currencies:
	     cooldown     - overrides the Charm's cooldown for that face; absent means
	                    fall back to the Charm's own value.
	     usesPerMatch - a per-tier array of per-match uses. NO fallback: only a face
	                    can impose a use budget, because a budget the other face
	                    never spends is not a property of the Charm. Augur is the
	                    only user today.

	3. omen = { type, intensity } - the Omen law (docs/DESIGN.md section 7): power
	   costs information. Every activation emits a public tell; intensity (always
	   the Charm's own rarity) is the master dial - it drives the OmenService
	   broadcast radius and how loud the client renders it. A stronger Charm cannot
	   be quieter than a weaker one, because the two values are the same field.

	4. loadoutWeight / essence - the weight budget and the Essence this Charm
	   donates when bound. Essences are Phase 4 (the Forge); the weight cap below is
	   read starting next prompt.

	No requires: this must be loadable from both server and client with no deps.
]]

local CharmDefs = {}

-- The loadout weight budget (docs/DESIGN.md sections 7 and 9): Common 1 / Rare 2 /
-- Epic 3, two slots, cap 4. It is what stops a double-Epic loadout - progression
-- buys expression, not oppression.
-- NOT ENFORCED YET: LoadoutService starts rejecting over-cap loadouts in the next
-- prompt. Declared here now so the number has exactly one home when it does.
CharmDefs.LOADOUT_WEIGHT_CAP = 4

-- Keyed by the EXISTING powerup ids - these stay stable; only DISPLAY strings
-- change in the re-theme.
CharmDefs.Charms = {
	SpeedBoost = {
		displayName = "Quickening",
		rarity = "Common",
		gachaWeight = 30,
		cooldown = 20,
		tiers = {
			{ speedMultiplier = 1.15, duration = 5 },
			{ speedMultiplier = 1.25, duration = 7 },
			{ speedMultiplier = 1.35, duration = 10 },
		},
		loadoutWeight = 1,
		essence = "Haste",
		faces = {
			-- Crew: the burst of speed that already shipped, to flee or to deliver.
			-- `tiers` is filled at the bottom of this file with the SAME table as
			-- the Charm's `tiers` above - not a copy.
			Crew = { tiers = nil },
			-- Vessel: a shorter, harder burst that lunges at the nearest player.
			-- Faster than any Crew tier but over almost immediately - a commitment,
			-- not a repositioning tool. Per-tier duration; mult and lungeRange are
			-- flat (rarity changes DEGREE, never whether you can act).
			Vessel = { mult = 1.6, duration = { 1.2, 1.5, 1.8 }, lungeRange = 20 },
		},
		omen = { type = "Draft", intensity = "Common" },
	},
	-- ============================================================
	-- RETIRED PENDING REWORK per design review. The original Flashlight never
	-- earned its slot: it only did anything during a Lights sabotage, and the
	-- price of using it was lighting yourself up for the Vessel. The Wick redesign
	-- (docs/DESIGN.md section 7) replaces it with a real dual-face Charm; until
	-- that lands this Charm does not enter play.
	--
	-- enabled = false is the ONE switch. Absent means enabled - every other Charm
	-- omits it. Consumers: GachaService (out of the roll pool and the odds math),
	-- LoadoutService (rejects it, and drops it when promoting a saved loadout),
	-- PowerupService (TryUse rejects it), HubUI (renders it dimmed).
	--
	-- OWNERSHIP DATA FOR THIS CHARM IS PRESERVED AND MUST NEVER BE DELETED. Tiers
	-- and banked duplicates stay in every player's persisted record exactly as
	-- they are, so un-retiring it needs no migration and no restitution.
	-- ============================================================
	Flashlight = {
		enabled = false,
		-- The name carries the retirement so it reads correctly everywhere it is
		-- already rendered (hub catalog, loadout picker) with no UI change. The
		-- Wick rework fills in faces/omen; nothing else about this entry moves
		-- until then.
		displayName = "Wick (reworking)",
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
		displayName = "Shroud",
		rarity = "Rare",
		gachaWeight = 20,
		cooldown = 40,
		tiers = {
			{ duration = 6 },
			{ duration = 9 },
			{ duration = 12 },
		},
		loadoutWeight = 2,
		essence = "Veil",
		faces = {
			-- Crew: veil-step - the Vessel's veil-sight loses you briefly. Much
			-- shorter than the Vessel face because it answers ONE moment (being
			-- hunted), not a whole approach.
			-- The veil-step flavor - what it looks like to break a hunter's read -
			-- lands in Phase 3 alongside veil-sight itself; for now the tuning is
			-- here and the behavior is still the existing single implementation.
			Crew = { duration = { 4, 6, 8 } },
			-- Vessel: the classic stalking invisibility that already shipped.
			-- KILL-BREAK RULE (unchanged, and load-bearing): landing a kill drops
			-- the effect immediately - PowerupService cancels it on OnKillPerformed.
			-- It buys the approach, never the escape.
			Vessel = { tiers = nil }, -- filled at the bottom of this file
		},
		omen = { type = "ColdTrail", intensity = "Rare" },
	},
	Shapeshifter = {
		displayName = "Guise",
		rarity = "Epic",
		gachaWeight = 10,
		cooldown = 60,
		tiers = {
			{ duration = 15 },
			{ duration = 20 },
			{ duration = 25 },
		},
		loadoutWeight = 3,
		essence = "Mirage",
		faces = {
			-- Crew: project an afterimage of yourself elsewhere - an alibi-maker.
			-- Shorter than the disguise because a decoy you are not standing next
			-- to is unfalsifiable while it lasts.
			Crew = { decoyDuration = { 8, 10, 12 } },
			-- Vessel: copy a nearby player's appearance + display name, exactly as
			-- it already ships (Player.Name is never touched - real identity is
			-- never falsified server-side).
			Vessel = { tiers = nil }, -- filled at the bottom of this file
		},
		omen = { type = "MirrorChime", intensity = "Epic" },
	},
	-- HUNTING WANTS RHYTHM, READING WANTS SCARCITY. Augur is the Charm whose two
	-- faces are paced by different currencies, and the resource values below are
	-- what make that real rather than aspirational: the Crew read is rationed by a
	-- per-match budget it can exhaust, the Vessel mark is rationed by a clock it
	-- can always wait out. A hunter denied their kit is a stalled match; an
	-- investigator with unlimited reads is a solved one. Neither face may spend the
	-- other's currency - which is why usesPerMatch lives on the FACE and not in
	-- `tiers`, where the shared gate used to charge both faces for it.
	Seer = {
		displayName = "Augur",
		rarity = "Epic",
		gachaWeight = 10,
		cooldown = 30,
		tiers = {
			{ minAlive = 5 },
			{ minAlive = 4 },
			{ minAlive = 4 },
		},
		loadoutWeight = 3,
		essence = "Insight",
		faces = {
			-- Crew: read a nearby soul's true role, as it already ships - the
			-- per-tier minAlive gate from `tiers` plus its own per-match uses (the
			-- scarcity precedent for the strongest effects). Values unchanged from
			-- when they lived in `tiers`.
			Crew = {
				tiers = nil, -- filled at the bottom of this file
				usesPerMatch = { 1, 1, 2 },
			},
			-- Vessel: mark prey - see the target through walls briefly. Cooldown
			-- only; it declares no usesPerMatch, so it can never draw down the
			-- Crew face's budget.
			Vessel = { markDuration = { 6, 8, 10 }, cooldown = 30 },
		},
		omen = { type = "Whisper", intensity = "Epic" },
	},
}

-- ============================================================
-- The face that already existed points at the SAME per-tier table as the Charm's
-- `tiers`, not a copy - a Lua table literal cannot reference itself, so it is
-- wired here. Tuning `tiers` therefore moves both, and the two can never drift.
-- ============================================================
CharmDefs.Charms.SpeedBoost.faces.Crew.tiers = CharmDefs.Charms.SpeedBoost.tiers
CharmDefs.Charms.Invisibility.faces.Vessel.tiers = CharmDefs.Charms.Invisibility.tiers
CharmDefs.Charms.Shapeshifter.faces.Vessel.tiers = CharmDefs.Charms.Shapeshifter.tiers
CharmDefs.Charms.Seer.faces.Crew.tiers = CharmDefs.Charms.Seer.tiers

return CharmDefs
