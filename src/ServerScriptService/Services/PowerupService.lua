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

	THE DUAL-FACE LAW (docs/DESIGN.md section 7): loadouts lock BEFORE roles are
	assigned, so every Charm has a Crew face and a Vessel face and the choice
	between them is made at USE time, from the user's role - see the face
	resolution in TryUse. Every gate runs first and is role-blind on purpose.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local CharmDefs = require(ReplicatedStorage.Modules.CharmDefs)
local GameConstants = require(ReplicatedStorage.Modules.GameConstants)
-- OmenService requires ONLY Remotes and nothing requires it back, so this cannot
-- close a cycle (see the audit below for the rest).
local OmenService = require(ServerScriptService.Services.OmenService)
-- A plain table of booleans that requires nothing, so it cannot close a cycle.
local DebugFlags = require(ServerScriptService.Services.DebugFlags)
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
-- ============================================================
-- Definitions now live in the shared CharmDefs module (the single source of
-- truth the Charm system interprets); this service is an interpreter of them.
-- The public alias is kept so existing readers (GachaService, Bootstrap's
-- DebugGrantMax) are unaffected. Per-entry shape: displayName, rarity,
-- gachaWeight (gacha roll weight), cooldown (seconds), tiers = array [1..3] of
-- stat tables (plus Phase 2 scaffold fields that nothing here reads).
PowerupService.Definitions = CharmDefs.Charms

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

-- player -> { [powerupId] = usesRemainingThisMatch } (only for Charms whose
-- RESOLVED FACE declares usesPerMatch; lazily initialized in TryUse). Keyed by
-- Charm id alone: a player's role cannot change inside a match, so only one face
-- of a Charm is ever reachable per player per match.
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

-- Returns the whole gacha odds table (one entry per ROLLABLE powerup): the
-- chance of rolling each powerup, sorted by rarity rank then descending percent.
-- { {powerupId, displayName, rarity, percent}, ... }
--
-- Retired Charms (enabled == false) are left out of BOTH the total and the list,
-- exactly as GachaService leaves them out of the roll pool. That is not a
-- cosmetic choice: this function exists so displayed odds and the actual roll can
-- never drift apart, and counting a Charm that cannot be rolled would break it.
function PowerupService.GetOdds()
	local totalWeight = 0
	for _, def in pairs(PowerupService.Definitions) do
		if def.enabled ~= false then
			totalWeight += def.gachaWeight
		end
	end

	local odds = {}
	for id, def in pairs(PowerupService.Definitions) do
		if def.enabled == false then
			continue
		end
		table.insert(odds, {
			powerupId = id,
			displayName = def.displayName,
			rarity = def.rarity,
			percent = math.floor((def.gachaWeight / totalWeight) * 1000 + 0.5) / 10, -- one decimal
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

-- Fires the Charm's declared Omen (docs/DESIGN.md section 7): power costs
-- information. Defaults to the user's own position; positionOverride exists for
-- omens that belong somewhere else in the world (Guise's decoy announces itself
-- where the decoy stands, not where the user is). A Charm with no omen declared
-- is a silent no-op.
--
-- ONLY EVER CALLED ON SUCCESS. A rejected activation - no target, min-alive
-- unmet, no character - emits nothing, because a failed use is not power spent
-- and must not cost information. Every call site sits after the last point the
-- face can still return false.
local function emitCharmOmen(player, powerupId, positionOverride)
	local omen = CharmDefs.Charms[powerupId] and CharmDefs.Charms[powerupId].omen
	if not omen then
		return
	end
	OmenService.Emit(player, omen.type, omen.intensity, positionOverride)
end

-- Starts the Charm's declared Omen as a repeating trail and returns the
-- canceller, for effects that last (Shroud). Callers MUST store the canceller on
-- the effect's registry entry so every existing cancel path stops the trail too.
local function startCharmOmenTrail(player, powerupId, interval)
	local omen = CharmDefs.Charms[powerupId] and CharmDefs.Charms[powerupId].omen
	if not omen then
		return nil
	end
	return OmenService.EmitSustained(player, omen.type, omen.intensity, interval)
end

-- ============================================================
-- Charm handlers, keyed by id then by FACE: { Crew = fn, Vessel = fn }.
--
-- Each face takes (player, stats, tier) and returns true on success, or
-- (false, reason) to fail the use BEFORE any state (cooldown/uses) is committed.
-- `stats` is the Charm's own tier row (CharmDefs.Charms[id].tiers[tier]), and
-- `tier` is there for faces whose tuning lives in per-tier arrays on the face
-- itself - including the resource values TryUse's second gate stage reads.
--
-- Timed effects register onto the active-effect registry and self-expire via the
-- entry-identity token pattern. Both faces of a Charm register under the SAME
-- registry key (its id), so cooldowns, the AlreadyActive gate, meeting/death
-- cancellation and the kill-break rule all keep working without knowing which
-- face is running.
--
-- All four enabled Charms now have both faces for real - no aliases remain. Each
-- Charm's pre-existing behavior survives as ONE of its two faces, unchanged;
-- Flashlight/Wick is registered under both faces only to keep the shape uniform
-- while it is retired.
-- ============================================================
local charmHandlers = {}

charmHandlers.SpeedBoost = {
	-- QUICKENING, Crew face: the burst of speed to flee or to deliver. Unchanged
	-- from what shipped - CharmDefs.faces.Crew.tiers IS the Charm's `tiers` table
	-- (wired in CharmDefs, not copied), so this reads the same numbers `stats`
	-- already holds; going through the face is what makes the grammar explicit.
	Crew = function(player, _stats, tier)
		local face = CharmDefs.Charms.SpeedBoost.faces.Crew
		local tierStats = face.tiers[tier]

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
		humanoid.WalkSpeed = entry.originalSpeed * tierStats.speedMultiplier

		task.delay(tierStats.duration, function()
			if activeEffects[player] and activeEffects[player]["SpeedBoost"] == entry then
				cancelEffect(player, "SpeedBoost")
			end
		end)

		emitCharmOmen(player, "SpeedBoost")
		return true
	end,

	-- QUICKENING, Vessel face: a shorter, harder burst that lunges at the nearest
	-- player. Same effect registry and the same identity-token expiry as the Crew
	-- face - only the numbers and the one-time orient differ.
	Vessel = function(player, _stats, tier)
		local face = CharmDefs.Charms.SpeedBoost.faces.Vessel

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return false, "NoCharacter"
		end

		local duration = face.duration[tier] or face.duration[#face.duration]

		local entry = { originalSpeed = humanoid.WalkSpeed }
		entry.cancel = function()
			local char = player.Character
			local h = char and char:FindFirstChildOfClass("Humanoid")
			if h then
				h.WalkSpeed = entry.originalSpeed
			end
		end
		startEffect(player, "SpeedBoost", entry)
		humanoid.WalkSpeed = entry.originalSpeed * face.mult

		-- The lunge is ORIENTATION ONLY, applied once at activation: the user is
		-- turned to face the nearest other living player, and the speed does the
		-- rest. No impulse, no velocity, no BodyMover - a physics kick on a
		-- client-owned character replicates as a shove (it would fight the
		-- Humanoid's own movement, jitter for the victim, and double as a
		-- ragdoll/launch griefing tool). Turning the hunter toward their prey is
		-- the whole fantasy and costs nothing in authority.
		local root = character:FindFirstChild("HumanoidRootPart")
		local target = findNearestOtherAlive(player, face.lungeRange)
		local targetRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
		if root and targetRoot then
			-- Y flattened to the user's own height so the character never tips.
			local look = Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
			if (look - root.Position).Magnitude > 0.01 then
				root.CFrame = CFrame.lookAt(root.Position, look)
			end
		end
		-- No target in range: the burst still fires, it just doesn't orient. The
		-- Charm is never wasted for want of prey.

		task.delay(duration, function()
			if activeEffects[player] and activeEffects[player]["SpeedBoost"] == entry then
				cancelEffect(player, "SpeedBoost")
			end
		end)

		emitCharmOmen(player, "SpeedBoost")
		return true
	end,
}

-- ============================================================
-- SHROUD (Invisibility). Both faces run the same concealment - only the duration
-- differs, and that difference is the whole design: the Vessel buys an approach,
-- the crew buys one moment of not being seen.
--
-- THE KILL-BREAK RULE is untouched: KillSystem.OnKillPerformed cancels this
-- effect on the killer (see the wiring at the bottom of the file). The Crew face
-- needs NO special-casing for it - crew cannot kill, so the hook simply never
-- fires for them. One rule, one place, no per-face branch.
--
-- THE OMEN is a TRAIL, not a moment: concealment that lasts must keep costing
-- information for as long as it lasts. The canceller returned by EmitSustained is
-- stored ON THE REGISTRY ENTRY and called from entry.cancel, so every existing
-- cancel path - duration expiry, meeting start, death, match start, a manual
-- cancelEffect - stops the trail as well. The trail can never outlive the
-- invisibility that pays for it.
-- ============================================================
local SHROUD_TRAIL_INTERVAL = 1.2

local function applyShroud(player, duration)
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
		if entry.cancelTrail then
			entry.cancelTrail()
			entry.cancelTrail = nil
		end
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

	task.delay(duration, function()
		if activeEffects[player] and activeEffects[player]["Invisibility"] == entry then
			cancelEffect(player, "Invisibility")
		end
	end)

	entry.cancelTrail = startCharmOmenTrail(player, "Invisibility", SHROUD_TRAIL_INTERVAL)
	return true
end

charmHandlers.Invisibility = {
	-- Crew face - veil-step: the same concealment at the shorter Crew durations.
	Crew = function(player, _stats, tier)
		local face = CharmDefs.Charms.Invisibility.faces.Crew
		return applyShroud(player, face.duration[tier] or face.duration[#face.duration])
	end,

	-- Vessel face - the stalking invisibility that already shipped, reading the
	-- Vessel face's tiers (the same table as the Charm's `tiers`).
	Vessel = function(player, _stats, tier)
		local face = CharmDefs.Charms.Invisibility.faces.Vessel
		return applyShroud(player, face.tiers[tier].duration)
	end,
}

-- ============================================================
-- GUISE (Shapeshifter). Vessel wears someone else; crew leaves someone else
-- behind. Both faces register under the "Shapeshifter" key, so the three cancel
-- paths this Charm needs - the user's death (RoleManager.OnAliveChanged), meeting
-- start (MeetingSystem.OnMeetingStart) and match start (MatchService.OnMatchStart)
-- - are ALREADY registered once at module level, at the bottom of this file. No
-- per-activation connections are made anywhere in here; a decoy cannot leak past
-- a death, a séance or a round boundary.
-- ============================================================

-- VESSEL FACE - the disguise that already shipped, unchanged.
--
-- Design note: Player.Name is NEVER touched, so votes, reports, Seer results
-- and corpse identity always tell the truth - the disguise is purely
-- audiovisual (appearance + overhead DisplayName). Reverting on death happens
-- BEFORE ragdoll conversion because RoleManager.SetAlive fires OnAliveChanged
-- first (see the OnAliveChanged wiring below).
local function wearGuise(player, tier)
	local face = CharmDefs.Charms.Shapeshifter.faces.Vessel
	local stats = face.tiers[tier]

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

	-- The mirror cracks where the change happens - at the user.
	emitCharmOmen(player, "Shapeshifter")
	return true
end

-- CREW FACE - the decoy afterimage, an alibi-maker.
--
-- THE DECOY IS NOT A PLAYER. It is an anchored, scriptless copy of the user's rig
-- parented to workspace: unkillable and unreportable BY CONSTRUCTION, not by a
-- rule someone has to remember - KillSystem only ever resolves against Players,
-- and body reports only ever find real corpses. Nothing had to be taught about
-- it. Its cost is readability: it does not move, breathe or animate, so anyone
-- who walks up to it knows exactly what they are looking at. It buys distance,
-- not scrutiny.
local function spawnDecoy(player, tier)
	local face = CharmDefs.Charms.Shapeshifter.faces.Crew
	local duration = face.decoyDuration[tier] or face.decoyDuration[#face.decoyDuration]

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then
		return false, "NoCharacter"
	end

	-- One decoy per player, and reactivation replaces rather than accumulates.
	-- TryUse's AlreadyActive gate normally makes this unreachable; it stays so the
	-- guarantee lives here, next to the thing it guarantees, rather than depending
	-- on a gate several hundred lines away.
	cancelEffect(player, "Shapeshifter")

	-- Player characters ship with Archivable false, so :Clone() returns nil unless
	-- it is flipped. Flip, clone, put it straight back - never leave a live player
	-- rig archivable, or anything else that clones the workspace picks it up.
	local wasArchivable = character.Archivable
	character.Archivable = true
	local decoy = character:Clone()
	character.Archivable = wasArchivable
	if not decoy then
		return false, "NoCharacter"
	end

	for _, desc in ipairs(decoy:GetDescendants()) do
		if desc:IsA("BaseScript") then
			-- Every Script/LocalScript, Animate above all: a cloned rig that keeps
			-- its scripts would idle-breathe and wander, and the afterimage would
			-- stop being a still image.
			desc:Destroy()
		elseif desc:IsA("BasePart") then
			-- Anchored so no physics, no falling, no drift. ACCEPTED, playtest
			-- question, do NOT silently "fix": collision is left exactly as the
			-- rig had it, so a decoy is a solid object in the room. Whether that
			-- reads as physical presence or as a doorway-blocking exploit is a
			-- tuning call for the first playtest, not a code decision made here.
			desc.Anchored = true
		end
	end

	local decoyHumanoid = decoy:FindFirstChildOfClass("Humanoid")
	if decoyHumanoid then
		decoyHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	-- The model wears the user's CURRENT display name, so anything that reads a
	-- name off the world sees the person it is imitating.
	decoy.Name = humanoid.DisplayName
	decoy:PivotTo(character:GetPivot())
	decoy.Parent = workspace

	local entry = {
		decoy = decoy,
		originalDisplayDistanceType = humanoid.DisplayDistanceType,
	}
	entry.cancel = function()
		if entry.decoy then
			entry.decoy:Destroy()
			entry.decoy = nil
		end
		local char = player.Character
		local h = char and char:FindFirstChildOfClass("Humanoid")
		if h then
			h.DisplayDistanceType = entry.originalDisplayDistanceType
		end
	end
	-- The user's own nametag goes dark for as long as the decoy stands. Both
	-- figures are nameless, so at a distance neither can be told from the other -
	-- which is the entire alibi. Restored when the decoy ends.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	startEffect(player, "Shapeshifter", entry)

	task.delay(duration, function()
		if activeEffects[player] and activeEffects[player]["Shapeshifter"] == entry then
			cancelEffect(player, "Shapeshifter")
		end
	end)

	-- The omen belongs to the DECOY, not the user: the mirror-crack announces
	-- where the false image appeared. Anyone in earshot of the decoy learns
	-- something happened there - and the user, standing elsewhere, may well be
	-- outside their own omen's radius. That is the Charm's whole trade.
	emitCharmOmen(player, "Shapeshifter", decoy:GetPivot().Position)
	return true
end

charmHandlers.Shapeshifter = {
	Crew = function(player, _stats, tier)
		return spawnDecoy(player, tier)
	end,
	Vessel = function(player, _stats, tier)
		return wearGuise(player, tier)
	end,
}

-- ============================================================
-- AUGUR (Seer). Crew reads a soul; the Vessel marks prey. Both are instant -
-- no registry entry, no cancel - and both find their subject through the SAME
-- proximity rule (findNearestOtherAlive at TARGET_RANGE): a living OTHER player
-- within arm's reach. You must stand next to someone to learn anything about
-- them, whichever face you carry.
--
-- BOTH FACES EMIT THE WHISPER. Reading souls is loud in both directions: the
-- Vessel picking a target and the crew checking a suspect sound identical to the
-- room, so hearing a whisper tells you someone is looking - never who, and never
-- which way. That symmetry is the point; it would be worth nothing if only one
-- role paid for it.
-- ============================================================
charmHandlers.Seer = {
	-- Crew face - the soul read that already shipped, including the per-tier
	-- minAlive gate and the per-match uses TryUse spends around it.
	Crew = function(player, stats)
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

		-- The reveal goes to the USER only.
		Remotes.Get(Remotes.Names.SeerResult):FireClient(player, target.Name, RoleManager.GetRole(target))
		emitCharmOmen(player, "Seer")
		return true
	end,

	-- Vessel face - mark prey: the target reads through walls for the user alone.
	-- The server holds NO state for this beyond the cooldown TryUse already
	-- commits: the mark is a fire-and-forget instruction to one client, so there
	-- is nothing to expire, cancel or clean up here.
	--
	-- No minAlive gate - that scarcity belongs to reading roles, not to hunting.
	Vessel = function(player, _stats, tier)
		local face = CharmDefs.Charms.Seer.faces.Vessel

		local target = findNearestOtherAlive(player, TARGET_RANGE)
		if not target then
			return false, "NoTargetNearby"
		end

		local duration = face.markDuration[tier] or face.markDuration[#face.markDuration]
		-- To the USER ONLY - nobody else may learn who was marked.
		Remotes.Get(Remotes.Names.PowerupEffect):FireClient(player, "AugurMark", "Start", {
			targetUserId = target.UserId,
			duration = duration,
		})
		emitCharmOmen(player, "Seer")
		return true
	end,
}

-- ============================================================
-- Augur's two currencies are now enforced, not coincidental: TryUse's second gate
-- stage reads uses and cooldown from the RESOLVED FACE, so the Crew read spends
-- from its scarce per-match budget (faces.Crew.usesPerMatch) while the Vessel mark
-- runs on faces.Vessel.cooldown alone and never touches that budget.
--
-- Still open: no client renders "AugurMark". PowerupFX ignores unknown powerup ids
-- in its PowerupEffect handler, so the remote lands harmlessly until the
-- through-walls highlight is built.
-- ============================================================

-- ============================================================
-- DORMANT - DEAD CODE, kept deliberately. Flashlight is RETIRED PENDING REWORK
-- (see CharmDefs), so TryUse rejects it with "Retired" before ever reaching
-- this handler. Nothing below runs today. It stays in place as the reference
-- implementation the Wick redesign (docs/DESIGN.md section 7) starts from -
-- delete it only once Wick replaces it. Registered under both faces purely so
-- the shape stays uniform; the Wick rework decides what each face really is.
-- ============================================================
local function flashlightLegacy(player, stats)
	if not LightsSystem.IsLightsOut() then
		return false, "LightsAreOn"
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return false, "NoCharacter"
	end

	-- A server-side light replicates to EVERYONE (impostor included), so the
	-- bearer glows in the dark like a held lantern rather than shining a beam.
	-- That beacon risk IS the trade-off: you see further, and everyone sees
	-- exactly where you are.
	local light = Instance.new("PointLight")
	light.Range = stats.glowRange
	light.Brightness = 1.6
	light.Color = Color3.fromRGB(255, 220, 160)
	light.Shadows = false
	light.Parent = head

	local entry = { light = light }
	entry.cancel = function()
		if light then
			light:Destroy()
		end
		Remotes.Get(Remotes.Names.PowerupEffect):FireClient(player, "Flashlight", "End", {})
	end
	startEffect(player, "Flashlight", entry)

	Remotes.Get(Remotes.Names.PowerupEffect):FireClient(player, "Flashlight", "Start", { fogEnd = stats.fogEnd })
	-- No duration - it ends when the lights come back on (OnLightsChanged) or
	-- on meeting/death/match reset.
	return true
end

charmHandlers.Flashlight = {
	Crew = flashlightLegacy,
	Vessel = flashlightLegacy,
}

-- Server-side handler for the UsePowerup RemoteEvent.
-- Returns (true, nil, cooldownSeconds) on success - the cooldown is for the
-- client HUD - or (false, reason) on failure.
--
-- Two gate stages with the face resolution between them:
--   STAGE 1  state gates - is this use legal at all? Role-blind, costs nothing.
--   FACE     which face is this player using?
--   STAGE 2  resource gates - what does it cost? Read from the resolved face.
function PowerupService.TryUse(player, powerupId)
	-- ============================================================
	-- STAGE 1: STATE GATES. Deliberately role-blind, every one of them: whether a
	-- use is ALLOWED must never depend on your role, only what it DOES when
	-- allowed. Nothing here consumes or arms anything, so any rejection below
	-- leaves the player exactly as they were.
	-- ============================================================
	if MatchService.GetState() ~= "InProgress" then
		return false, "MatchNotInProgress"
	end

	if MeetingSystem.IsMeetingActive() then
		return false, "MeetingActive"
	end

	-- A retired Charm never resolves, even if one somehow reached a slot.
	-- LoadoutService already refuses to equip and drops it when promoting a saved
	-- loadout, so this is the backstop, not the gate.
	local retiredCheck = PowerupService.Definitions[powerupId]
	if retiredCheck and retiredCheck.enabled == false then
		return false, "Retired"
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
	-- END OF STAGE 1. Everything above is role-blind and costs nothing.

	-- ============================================================
	-- FACE RESOLUTION (docs/DESIGN.md section 7, the dual-face law).
	-- Loadouts lock before roles are assigned, so which face a Charm shows can
	-- only be decided here, at use time. The Vessel gets the Vessel face; EVERY
	-- other case gets Crew - crew players, and defensively a roleless one (a nil
	-- role can never fall through to a nil handler and error).
	--
	-- It sits BETWEEN the two gate stages on purpose. Resolution is a pure lookup:
	-- it reads a role and picks a table, touching no cooldown, no use counter and
	-- no world state, so running it before the resource gates cannot cost a player
	-- anything even when those gates go on to reject.
	--
	-- WHY THE RESOURCE GATES MUST SEE THE FACE: a Charm's two faces can be paced
	-- by different currencies. Augur is the case that forced this - its Crew face
	-- reads souls on a scarce per-match budget, while its Vessel face marks prey on
	-- a cooldown rhythm and must NEVER touch that budget. Before this split, the
	-- Vessel's mark spent one of the crew read's uses, because the gate ran before
	-- anyone knew which face was being used.
	--
	-- No other Charm's behavior changes: their faces declare no cooldown and no
	-- usesPerMatch, so the fallbacks below reproduce today's values exactly.
	-- ============================================================
	local faceName = (RoleManager.GetRole(player) == GameConstants.Roles.Vessel) and "Vessel" or "Crew"
	local faces = charmHandlers[powerupId]
	local handler = faces and faces[faceName]
	if not handler then
		return false, "NotImplementedYet"
	end
	local face = def.faces and def.faces[faceName]

	-- ============================================================
	-- STAGE 2: RESOURCE GATES - what this use COSTS, read from the resolved face.
	-- Both are keyed by powerupId alone, not by face: a player's role cannot
	-- change inside a match, so only one face of a Charm is ever reachable per
	-- player per match and the two can never collide in these tables.
	-- ============================================================

	-- Per-match uses: ONLY the resolved face can impose them - there is no
	-- charm-level fallback, because a budget one face never spends is not a
	-- property of the Charm. Declared as a per-tier array on the face, matching
	-- how every other per-face tuning value is written. Lazily seed, then gate.
	local faceUses = nil
	if face and face.usesPerMatch then
		faceUses = face.usesPerMatch[tier] or face.usesPerMatch[#face.usesPerMatch]
	end

	local playerUses = usesLeft[player] or {}
	usesLeft[player] = playerUses
	if faceUses ~= nil then
		if playerUses[powerupId] == nil then
			playerUses[powerupId] = faceUses
		end
		if playerUses[powerupId] <= 0 then
			return false, "NoUsesLeft"
		end
	end

	-- Cooldown DOES fall back to the Charm's own value: every Charm has a pacing
	-- floor, and a face only overrides it when its rhythm genuinely differs.
	local faceCooldown = (face and face.cooldown) or def.cooldown

	local playerCooldowns = cooldowns[player] or {}
	cooldowns[player] = playerCooldowns
	-- DEBUG ONLY - NO_COOLDOWNS makes this GATE pass, read here at decision time.
	-- The commit below still arms the cooldown, which is harmless precisely because
	-- the gate no longer consults it: flipping the flag back off restores real
	-- pacing from whatever was armed while it was on, with no state to unwind.
	-- The per-match uses gate above is deliberately NOT bypassed.
	if not DebugFlags.NO_COOLDOWNS and os.clock() < (playerCooldowns[powerupId] or 0) then
		return false, "OnCooldown"
	end

	-- The handler may itself reject (e.g. NoTargetNearby, LightsAreOn) BEFORE any
	-- state is committed. `tier` rides along for faces whose tuning lives in
	-- per-tier arrays on the face rather than in the Charm's `tiers`.
	local ok, reason = handler(player, stats, tier)
	if not ok then
		return false, reason
	end

	-- Commit only on success, against the resolved face's values.
	playerCooldowns[powerupId] = os.clock() + faceCooldown
	if faceUses ~= nil then
		playerUses[powerupId] = playerUses[powerupId] - 1
	end

	-- The third return is for the client HUD's countdown chip and nothing else.
	-- While NO_COOLDOWNS is on the gate ignores the armed value, so reporting it
	-- would grey out a slot that is in fact usable - report 0 and the HUD draws no
	-- overlay at all.
	return true, nil, (DebugFlags.NO_COOLDOWNS and 0 or faceCooldown)
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
-- DORMANT with the handler above: no Flashlight can be active while it is
-- retired, so this loop finds nothing. Kept for the same reason.
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