--[[
	OmenFX.client.lua
	The SINGLE renderer for OmenEvent (docs/DESIGN.md section 7, the Omen law:
	power costs information - every Charm activation emits a public tell).

	The server has already decided WHO hears an omen: OmenService only fires this
	remote at players inside the intensity's radius, the source included. This
	script never re-checks distance, never filters by role, and never decides
	whether an omen deserves to be shown - it only draws what arrives. Keeping that
	rule is what makes omen loudness a single server-side dial.

	Built to grow: one handler table keyed by omenType. Adding an omen is adding a
	function here plus a CharmDefs entry - no dispatch to touch. Unknown types
	no-op, so an omen may ship server-side before its renderer exists.

	All four omens render: Draft (Quickening), ColdTrail (Shroud), MirrorChime
	(Guise) and Whisper (Augur). Rough but evocative placeholders - loud enough to
	playtest the Omen law, specific enough to seed the Phase 6 art and audio pass,
	and none of them final. Sounds are engine-bundled only.

	Deliberately NOT gated on ClientSettings.GetReduceEffects() - see the rule
	written out above the handler table.

	Everything transient lives under one folder and is swept on MatchEnded and
	CharacterAdded, plus a generation token so a sweep retires in-flight effects.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))
local omenEvent = Remotes.Get(Remotes.Names.OmenEvent)
local matchEndedEvent = Remotes.Get(Remotes.Names.MatchEnded)

local localPlayer = Players.LocalPlayer

-- Intensity scales presentation SUBTLY - the loud dial is the server's radius,
-- not the visuals. An Epic omen should read as "further away and still visible",
-- not as a different effect.
local INTENSITY_SCALE = {
	Common = 1,
	Rare = 1.15,
	Epic = 1.3,
}

-- ============================================================
-- Transient instance folder + generation token. Every effect parents its parts
-- here and captures the generation it was born in; a sweep bumps the token and
-- clears the folder, so a still-running effect finds itself stale and stops
-- rather than resurrecting anything into the next life or match.
-- ============================================================
local fxFolder = Instance.new("Folder")
fxFolder.Name = "OmenFX"
fxFolder.Parent = workspace

local generation = 0

local function sweep()
	generation += 1
	fxFolder:ClearAllChildren()
end

-- A part that exists only to be looked at: no collision, no queries, no shadow,
-- and never in anyone's way.
local function makeFxPart(size, cframe, color, material)
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- Engine-bundled asset, no marketplace or moderation dependency - the same
-- precedent EchoCode and the gacha reveal set. Pitched two ways: fast and high
-- for a mirror crack, slow and low for a whisper. The audio pass replaces it.
local PING_SOUND = "rbxasset://sounds/electronicpingshort.wav"

-- A quiet POSITIONAL one-shot at a world point. The Sound rides an invisible
-- anchored part inside the swept folder, so distance and direction do the work of
-- telling you where the omen came from - an omen you can hear but not locate
-- would be noise, not information. Cleaned up by Debris, and by the folder sweep
-- if a match ends first.
local function playOmenSound(position, assetId, pitch, volume, lifetime)
	local anchor = makeFxPart(
		Vector3.new(0.2, 0.2, 0.2),
		CFrame.new(position),
		Color3.new(0, 0, 0),
		Enum.Material.SmoothPlastic
	)
	anchor.Transparency = 1
	anchor.Parent = fxFolder

	local sound = Instance.new("Sound")
	sound.SoundId = assetId
	sound.PlaybackSpeed = pitch
	-- Master volume governs every client-created sound, exactly as the gacha
	-- reveal does it.
	sound.Volume = ClientSettings.ApplyVolume(volume)
	sound.RollOffMaxDistance = 60
	sound.Parent = anchor
	sound:Play()
	Debris:AddItem(anchor, lifetime)
end

-- ============================================================
-- Omen renderers, keyed by omenType.
--
-- OMENS NEVER GATE ON ReduceEffects. This is the codified rule, not an oversight
-- to be tidied up later: an Omen is game information the OTHER players are owed,
-- not flair for the person watching it. A setting that muted omens would let one
-- player buy silence for everyone else's Charms, which is the Omen law inverted.
-- Sounds respect the MASTER VOLUME, because that is how all audio works and a
-- muted game must stay muted; the visuals are unconditional.
-- ============================================================
local omenHandlers = {}

-- DRAFT - Quickening (SpeedBoost), both faces. "A rushing draft; dust kicks
-- visibly." Grey-brown motes thrown outward off the floor plus one pale
-- wind-streak, gone inside half a second. Readable at a glance, no sound yet.
omenHandlers.Draft = function(position, intensity)
	local myGeneration = generation
	local scale = INTENSITY_SCALE[intensity] or 1
	-- Kicked dust belongs near the ground, not at chest height where the payload
	-- position (the source's root) sits.
	local ground = position - Vector3.new(0, 2.4, 0)

	local dustColor = Color3.fromRGB(122, 106, 88)
	local count = math.random(6, 10)
	for _ = 1, count do
		local size = (0.22 + math.random() * 0.2) * scale
		local part = makeFxPart(
			Vector3.new(size, size, size),
			CFrame.new(ground + Vector3.new((math.random() - 0.5) * 1.2, math.random() * 0.6, (math.random() - 0.5) * 1.2)),
			dustColor,
			Enum.Material.SmoothPlastic
		)
		part.Transparency = 0.3
		part.Parent = fxFolder

		local angle = math.random() * math.pi * 2
		local distance = (2.5 + math.random() * 2.5) * scale
		local drift = Vector3.new(math.cos(angle) * distance, 0.8 + math.random() * 1.2, math.sin(angle) * distance)
		local lifetime = 0.35 + math.random() * 0.2

		TweenService:Create(part, TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(part.Position + drift),
			Transparency = 1,
			Size = Vector3.new(size * 0.4, size * 0.4, size * 0.4),
		}):Play()

		task.delay(lifetime + 0.05, function()
			-- Stale generation means a sweep already cleared the folder.
			if myGeneration == generation then
				part:Destroy()
			end
		end)
	end

	-- One faint horizontal streak through the burst - the draft itself. Neon so it
	-- reads as air rather than as another mote, and pointed on a random heading
	-- because the omen says "something rushed past here", not which way it went.
	local heading = math.random() * math.pi * 2
	local streak = makeFxPart(
		Vector3.new(0.12, 0.12, 4.5 * scale),
		CFrame.new(position - Vector3.new(0, 1.2, 0)) * CFrame.Angles(0, heading, 0),
		Color3.fromRGB(198, 190, 176),
		Enum.Material.Neon
	)
	streak.Transparency = 0.72
	streak.Parent = fxFolder

	TweenService:Create(streak, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
		Size = Vector3.new(0.05, 0.05, 7 * scale),
	}):Play()

	task.delay(0.45, function()
		if myGeneration == generation then
			streak:Destroy()
		end
	end)
end

-- COLDTRAIL - Shroud (Invisibility), both faces. "A cold-breath shimmer trail."
-- This one arrives as a PULSE, roughly once a second for as long as the
-- concealment lasts (OmenService.EmitSustained), so each pulse renders only a
-- breath's worth: a few tiny motes lifting slowly with a faint cold glow.
--
-- SUBTLE IS CORRECT HERE, and deliberately weaker than the other two - do NOT
-- "fix" it by making it louder. A trail is meant to be read by WATCHING: you
-- notice it because you were already looking at that corridor, and the reward for
-- paying attention is knowing someone shrouded passed through. An effect that
-- slapped you in the face would hand that read to everyone for free and turn the
-- Charm into a beacon. What makes it findable is that it repeats, not that any
-- one pulse is bright.
local COLD_COLOR = Color3.fromRGB(186, 224, 246)

omenHandlers.ColdTrail = function(position, intensity)
	local myGeneration = generation
	local scale = INTENSITY_SCALE[intensity] or 1

	for _ = 1, math.random(3, 5) do
		local size = (0.1 + math.random() * 0.09) * scale
		local part = makeFxPart(
			Vector3.new(size, size, size),
			CFrame.new(position + Vector3.new(
				(math.random() - 0.5) * 1.6,
				(math.random() - 0.5) * 2.2,
				(math.random() - 0.5) * 1.6
			)),
			COLD_COLOR,
			Enum.Material.Neon
		)
		part.Transparency = 0.45

		-- The "faint" in faint glow is load-bearing: enough to catch the eye in a
		-- dark corridor, not enough to light the room or give away a position at
		-- range on its own.
		local glow = Instance.new("PointLight")
		glow.Range = 4.5 * scale
		glow.Brightness = 0.32
		glow.Color = COLD_COLOR
		glow.Shadows = false
		glow.Parent = part -- destroyed with the part

		part.Parent = fxFolder

		-- Slow rise: cold breath drifting up, not particles being thrown.
		local lifetime = 0.9 + math.random() * 0.5
		local rise = Vector3.new(0, 1.4 + math.random() * 1.0, 0)
		TweenService:Create(part, TweenInfo.new(lifetime, Enum.EasingStyle.Linear), {
			CFrame = CFrame.new(part.Position + rise),
			Transparency = 1,
			Size = Vector3.new(size * 0.5, size * 0.5, size * 0.5),
		}):Play()

		task.delay(lifetime + 0.05, function()
			if myGeneration == generation then
				part:Destroy()
			end
		end)
	end
end

-- MIRRORCHIME - Guise (Shapeshifter). "A mirror-crack chime near the user." A
-- ring of thin glassy shards flung outward and spinning as they fade, plus a
-- short high ping. This is the loudest omen of the three, and should be: Guise is
-- Epic, and a false image entering the world is the single most consequential
-- thing a Charm does to another player's read of the room.
local MIRROR_COLOR = Color3.fromRGB(226, 232, 244)
local SHARD_COUNT = 4
local CHIME_LIFETIME = 0.5

omenHandlers.MirrorChime = function(position, intensity)
	local myGeneration = generation
	local scale = INTENSITY_SCALE[intensity] or 1

	for i = 1, SHARD_COUNT do
		-- Evenly spaced around the ring, jittered so it never looks stamped.
		local angle = (i - 1) * (math.pi * 2 / SHARD_COUNT) + (math.random() - 0.5) * 0.35
		local facing = CFrame.new(position) * CFrame.Angles(0, -angle, 0)

		local shard = makeFxPart(
			Vector3.new(0.07, 0.85 * scale, 0.22 * scale),
			facing * CFrame.new(0, 0, -0.7),
			MIRROR_COLOR,
			Enum.Material.Neon
		)
		shard.Transparency = 0.25
		shard.Parent = fxFolder

		-- Outward AND spinning: the tumble is what sells glass rather than light.
		local outward = facing
			* CFrame.new(0, (math.random() - 0.5) * 0.8, -(2.4 + math.random() * 1.1) * scale)
			* CFrame.Angles(math.random() * 4, math.random() * 4, math.random() * 4)

		TweenService:Create(shard, TweenInfo.new(CHIME_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = outward,
			Transparency = 1,
			Size = Vector3.new(0.03, 0.3 * scale, 0.08 * scale),
		}):Play()

		task.delay(CHIME_LIFETIME + 0.05, function()
			if myGeneration == generation then
				shard:Destroy()
			end
		end)
	end

	playOmenSound(position, PING_SOUND, 2.2, 0.28, 2)
end

-- WHISPER - Augur (Seer), both faces. "A whisper audible to nearby players."
-- Almost entirely an AUDIO omen: a low breathy tone with a dark ripple you catch
-- only if you happen to be looking straight at it. That imbalance is the design -
-- a whisper should tell you someone nearby is looking, and pointedly not tell you
-- who or which way, so the sound carries it and the visual barely helps.
local WHISPER_COLOR = Color3.fromRGB(24, 20, 32)
local WHISPER_LIFETIME = 0.55

omenHandlers.Whisper = function(position, intensity)
	local myGeneration = generation
	local scale = INTENSITY_SCALE[intensity] or 1

	-- A flat disc lying on the horizontal, expanding once. Rotated because a
	-- Cylinder's circular faces point along X by default.
	local ring = makeFxPart(
		Vector3.new(0.08, 1.2, 1.2),
		CFrame.new(position - Vector3.new(0, 1.0, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		WHISPER_COLOR,
		Enum.Material.SmoothPlastic
	)
	ring.Shape = Enum.PartType.Cylinder
	-- Barely visible on purpose. If this ever reads clearly at a glance it has
	-- stopped being a whisper.
	ring.Transparency = 0.86
	ring.Parent = fxFolder

	TweenService:Create(ring, TweenInfo.new(WHISPER_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.04, 7 * scale, 7 * scale),
		Transparency = 1,
	}):Play()

	task.delay(WHISPER_LIFETIME + 0.05, function()
		if myGeneration == generation then
			ring:Destroy()
		end
	end)

	-- Same asset as the chime, dropped to half speed: the ping becomes a breath.
	playOmenSound(position, PING_SOUND, 0.5, 0.1, 3)
end

-- ============================================================
-- Remote wiring.
-- ============================================================
omenEvent.OnClientEvent:Connect(function(payload)
	if type(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end

	local handler = omenHandlers[payload.omenType]
	if not handler then
		-- Unknown omen type: no-op BY DESIGN, not an oversight. New omens ship
		-- server-side first (a CharmDefs entry plus an OmenService.Emit call) and
		-- get their renderer in a later pass; a missing renderer must never error
		-- or spam the output. Uncomment to trace one:
		--   warn("[OmenFX] no renderer for omen type:", tostring(payload.omenType))
		return
	end

	handler(payload.position, payload.intensity)
end)

matchEndedEvent.OnClientEvent:Connect(sweep)
localPlayer.CharacterAdded:Connect(sweep)
