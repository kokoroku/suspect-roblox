--[[
	OmenService.lua
	The single emitter of world-visible tells (docs/DESIGN.md sections 7 & 11).

	THE OMEN LAW: power costs information. Every Charm activation emits a public
	Omen, and a stronger effect emits a louder one. Routing every tell through one
	service is what makes that law a single tunable dial instead of a pile of
	scattered effects that drift apart - if omens ever need to be quieter, the
	numbers below are the only place to change.

	Intensity is always the Charm's own rarity (see CharmDefs.omen), so a rarer
	Charm can never be stealthier than a common one. Intensity decides BOTH the
	broadcast radius here and how loudly OmenFX renders it on the client.

	Cycle-safety: this requires ONLY Remotes, so ANYTHING may require it -
	PowerupService, KillSystem, SabotageService, RitualService, a future
	SpiritService Muffle. It requires no service back and reacts to no hooks; it is
	a leaf that only ever gets called. Keep it that way.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)

local OmenService = {}

-- ============================================================
-- TUNING - the master loudness dial (docs/DESIGN.md section 7).
-- How far an omen carries, in studs, by intensity.
-- ============================================================
local RADIUS = {
	Common = 30,
	Rare = 40,
	Epic = 50,
}

-- sourcePlayer -> the token table of the sustained pulse that currently owns them.
-- Identity-token pattern (the same one PowerupService's effect registry uses): a
-- loop only keeps running while it is STILL the entry stored here, so a newer
-- sustained omen or a cancel silently retires the older loop.
local sustainedTokens = {}

-- Emits one omen pulse.
--   sourcePlayer     - who caused it (their UserId rides in the payload).
--   omenType         - a CharmDefs omen type string ("Draft", "ColdTrail", ...).
--   intensity        - "Common" | "Rare" | "Epic"; unknown falls back to Common.
--   positionOverride - optional Vector3; defaults to the source's root position.
-- With no override and no HumanoidRootPart there is nothing to place the omen at,
-- so this aborts silently - a missing character must never error out an
-- activation that already succeeded.
function OmenService.Emit(sourcePlayer, omenType, intensity, positionOverride)
	if not sourcePlayer or type(omenType) ~= "string" then
		return
	end

	local position = positionOverride
	if not position then
		local character = sourcePlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			return
		end
		position = root.Position
	end

	local radius = RADIUS[intensity] or RADIUS.Common
	local payload = {
		omenType = omenType,
		position = position,
		intensity = intensity,
		sourceUserId = sourcePlayer.UserId,
	}

	local omenEvent = Remotes.Get(Remotes.Names.OmenEvent)
	-- Everyone inside the radius, THE SOURCE INCLUDED (no skip for them): you
	-- perceive your own omens by design. That is how a player learns what their
	-- own Charm sounds and looks like to the room - and therefore learns what it
	-- costs them to use it. Without it, the Omen law would be invisible to the one
	-- person who most needs to feel it.
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - position).Magnitude <= radius then
			omenEvent:FireClient(player, payload)
		end
	end
end

-- A repeating omen for effects that last (a trail while shrouded, a sustained
-- channel). Pulses Emit immediately and then every `interval` seconds, following
-- the source as they move, and returns a canceller function.
--
-- Self-cancelling: the loop stops on its own when the source loses their
-- character, their HumanoidRootPart, their Humanoid, or dies, so no caller has to
-- remember to stop it on death - though effects with a real end (an expiry, a
-- meeting, a cancel) should still call the returned canceller.
--
-- UNUSED TODAY. Built now so the Phase 2 batch that adds the sustained faces
-- (Shroud's trail in particular) only consumes this - the emitter never has to be
-- reopened mid-batch.
function OmenService.EmitSustained(sourcePlayer, omenType, intensity, interval)
	if not sourcePlayer or type(omenType) ~= "string" then
		return function() end
	end
	if type(interval) ~= "number" or interval <= 0 then
		interval = 1
	end

	local token = {}
	sustainedTokens[sourcePlayer] = token

	local function isCurrent()
		return sustainedTokens[sourcePlayer] == token
	end

	local function cancel()
		-- Only clear if we are still the owner - a later pulse must not be killed
		-- by an older canceller firing late.
		if isCurrent() then
			sustainedTokens[sourcePlayer] = nil
		end
	end

	task.spawn(function()
		while isCurrent() do
			local character = sourcePlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not sourcePlayer.Parent or not character or not humanoid or not root or humanoid.Health <= 0 then
				cancel()
				break
			end
			OmenService.Emit(sourcePlayer, omenType, intensity)
			task.wait(interval)
		end
	end)

	return cancel
end

Players.PlayerRemoving:Connect(function(player)
	sustainedTokens[player] = nil
end)

return OmenService
