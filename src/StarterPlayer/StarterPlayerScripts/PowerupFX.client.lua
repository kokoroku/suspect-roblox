--[[
	PowerupFX.client.lua
	The ONE client-side owner of Lighting changes plus self-only powerup visuals.
	Single owner on purpose - nothing else should write to the shared Lighting
	service, so there is never a race over fog/ambient.

	RULE (unchanged): this file is the ONLY writer of client Lighting. Nothing
	else may touch fog/ambient/brightness, so there is never a race over them and
	the captured baseline below is always a true "lights on" snapshot.

	Lights-out is driven by the server (SabotageService -> LightsSystem ->
	LightsChanged). The server also kills the tagged RoomLamp parts, so the world
	darkens for everyone; THIS file only decides how far the local player can see
	in that dark, by role.

	Built entirely in code, deliberately rough - full styling comes in the UI
	rehaul pass.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local GameConstants = require(ReplicatedStorage.Modules.GameConstants)
local roleAssignedEvent = Remotes.Get(Remotes.Names.RoleAssigned)
local lightsChangedEvent = Remotes.Get(Remotes.Names.LightsChanged)
local powerupEffectEvent = Remotes.Get(Remotes.Names.PowerupEffect)
local debugToggleLightsEvent = Remotes.Get(Remotes.Names.DebugToggleLights)
local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)
local matchEndedEvent = Remotes.Get(Remotes.Names.MatchEnded)

local localPlayer = Players.LocalPlayer

-- ============================================================
-- TUNING - how far each role sees once the lights are out.
-- ============================================================
local CREW_FOG_END = 35
local IMPOSTOR_FOG_END = 90
local DARK_FOG_COLOR = Color3.fromRGB(5, 5, 8)
local CREW_AMBIENT = Color3.fromRGB(8, 8, 10)
local CREW_OUTDOOR_AMBIENT = Color3.fromRGB(10, 10, 12)
local CREW_BRIGHTNESS = 0.6
local IMPOSTOR_AMBIENT = Color3.fromRGB(28, 28, 32)
local IMPOSTOR_OUTDOOR_AMBIENT = Color3.fromRGB(32, 32, 36)

-- The crew's personal candle: a small light on your own head that only YOU can
-- see (see updateCandle).
local CANDLE_RANGE = 6
local CANDLE_BRIGHTNESS = 0.9
local CANDLE_COLOR = Color3.fromRGB(255, 200, 140)

local IMPOSTOR_ROLE = GameConstants.Roles.Vessel

-- Snapshot the map's lit look ONCE, before anything here has modified it, so
-- every restore puts back exactly what the map shipped with.
local baseFogEnd = Lighting.FogEnd
local baseFogColor = Lighting.FogColor
local baseAmbient = Lighting.Ambient
local baseOutdoorAmbient = Lighting.OutdoorAmbient
local baseBrightness = Lighting.Brightness

local ownRole = nil
local lightsOut = false
local flashlightActive = false
local flashlightFogEnd = CREW_FOG_END

-- The one live candle PointLight, or nil.
local candle = nil

local function destroyCandle()
	if candle then
		candle:Destroy()
		candle = nil
	end
end

-- The crew's personal glow. The light is created CLIENT-side, so it exists only
-- in this player's own view - the 3D analog of the Among Us personal vision
-- circle. Anything inside the radius is lit for you, other players included;
-- other crew's candles are invisible to you by construction, because their
-- candles were never replicated to your client at all.
--
-- Exactly one candle may ever exist, and none while the lights are on, while
-- impostor, or while dead. Death needs its OWN check: player.Character keeps
-- pointing at the ragdoll after a kill, so the Head outlives the player and a
-- head-only test would leave a candle burning on the corpse.
local function updateCandle()
	local character = localPlayer.Character
	local head = character and character:FindFirstChild("Head")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local alive = humanoid ~= nil and humanoid.Health > 0

	if not lightsOut or ownRole == IMPOSTOR_ROLE or not head or not alive then
		destroyCandle()
		return
	end

	if candle and candle.Parent == head then
		return -- already lit on the current character; nothing to rebuild
	end

	destroyCandle() -- stale candle on a previous character
	candle = Instance.new("PointLight")
	candle.Range = CANDLE_RANGE
	candle.Brightness = CANDLE_BRIGHTNESS
	candle.Color = CANDLE_COLOR
	candle.Shadows = false
	candle.Parent = head
end

-- INVARIANT: only a CONFIRMED impostor gets the sighted treatment. Crew, ghosts,
-- and a nil/unknown role all fall into the impaired branch. Failing dark is a
-- nuisance for one player; failing sighted silently deletes the whole mechanic -
-- that exact inversion (unknown role reading as unimpaired) is the bug this
-- rework fixes, so the impaired branch must stay the default, never the fallback.
local function applyLighting()
	-- Folded in here so every existing call site (role, lights, flashlight)
	-- maintains the candle too - no separate event plumbing for it.
	updateCandle()

	if not lightsOut then
		Lighting.FogEnd = baseFogEnd
		Lighting.FogColor = baseFogColor
		Lighting.Ambient = baseAmbient
		Lighting.OutdoorAmbient = baseOutdoorAmbient
		Lighting.Brightness = baseBrightness
		return
	end

	Lighting.FogColor = DARK_FOG_COLOR

	if ownRole == IMPOSTOR_ROLE then
		-- Impostors see across the dark rooms - the genre's standard asymmetry.
		Lighting.FogEnd = IMPOSTOR_FOG_END
		Lighting.Ambient = IMPOSTOR_AMBIENT
		Lighting.OutdoorAmbient = IMPOSTOR_OUTDOOR_AMBIENT
		Lighting.Brightness = baseBrightness
		return
	end

	-- Crew / ghost / unknown role: impaired. An active own-Flashlight widens the
	-- fog to the tier's fogEnd instead of the crew value; nothing else changes.
	-- The candle coexists with it happily - the flashlight's glow is a separate
	-- server-side light on the character, this is local fog.
	--
	-- DORMANT: Flashlight is RETIRED PENDING REWORK (see CharmDefs), so the server
	-- never fires its PowerupEffect and flashlightActive can no longer become true
	-- - this override always falls through to CREW_FOG_END today. The path stays
	-- intact for the Wick redesign (docs/DESIGN.md section 7).
	Lighting.FogEnd = flashlightActive and flashlightFogEnd or CREW_FOG_END
	Lighting.Ambient = CREW_AMBIENT
	Lighting.OutdoorAmbient = CREW_OUTDOOR_AMBIENT
	Lighting.Brightness = CREW_BRIGHTNESS
end

-- The server sends each player their own role at EVERY match's role assignment,
-- so this re-decides the branch each round (an impostor last match is not an
-- impostor this one). It is the only source of ownRole.
roleAssignedEvent.OnClientEvent:Connect(function(role)
	ownRole = role
	applyLighting()
end)

lightsChangedEvent.OnClientEvent:Connect(function(state)
	lightsOut = state
	applyLighting()
end)

-- A respawn is a brand-new character, so the old candle went with the old head.
-- applyLighting rebuilds it on the new one (and drops it if it shouldn't exist).
-- Died is wired per character so dying snuffs the candle at that instant instead
-- of leaving it on the corpse until the next lights/role change.
local function watchCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Connect(function()
			applyLighting()
		end)
	end
	applyLighting()
end

if localPlayer.Character then
	watchCharacter(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(watchCharacter)

-- ============================================================
-- AUGUR MARK - the Vessel face of Augur (docs/DESIGN.md section 7): mark prey and
-- see them through walls for a few seconds.
--
-- THE SERVER NEVER CREATES THIS HIGHLIGHT. Highlight instances replicate, so a
-- server-made one would glow on EVERY client - the marked player would see
-- themselves lit up, and so would every bystander. That inverts the mechanic: a
-- mark the target can see is a warning, not a hunt. The server therefore sends
-- only an instruction (targetUserId + duration) to the marker alone, and the
-- Highlight is built here, locally. It exists on exactly one screen by design.
--
-- Cleared at duration, on the target dying or leaving, on meeting start, and on
-- MatchEnded; an "End" payload clears it early. Token-guarded so a second mark
-- supersedes the first cleanly.
-- ============================================================
local MARK_FILL_TRANSPARENCY = 0.6
local MARK_OUTLINE_COLOR = Color3.fromRGB(214, 178, 74) -- sickly gold
local MARK_FILL_COLOR = Color3.fromRGB(120, 96, 30)

local markHighlight = nil
local markToken = 0
local markConns = {}

local function clearMark()
	markToken += 1
	for _, conn in ipairs(markConns) do
		conn:Disconnect()
	end
	markConns = {}
	if markHighlight then
		markHighlight:Destroy()
		markHighlight = nil
	end
end

local function startMark(data)
	clearMark() -- one mark at a time; a new one always replaces
	if type(data) ~= "table" then
		return
	end

	local target = Players:GetPlayerByUserId(data.targetUserId)
	local character = target and target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then
		return -- nothing to mark; the server already spent the cooldown, not our call
	end

	-- clearMark above already bumped the token, so this value is ours alone.
	local myToken = markToken

	local highlight = Instance.new("Highlight")
	highlight.Adornee = character
	highlight.FillColor = MARK_FILL_COLOR
	highlight.FillTransparency = MARK_FILL_TRANSPARENCY
	highlight.OutlineColor = MARK_OUTLINE_COLOR
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- the through-walls part
	highlight.Parent = character
	markHighlight = highlight

	local function expireIfCurrent()
		if myToken == markToken then
			clearMark()
		end
	end

	-- The mark dies with its subject: a highlight left burning on a corpse or on a
	-- player who left would keep pointing at something that is no longer prey.
	table.insert(markConns, humanoid.Died:Connect(expireIfCurrent))
	table.insert(markConns, target.AncestryChanged:Connect(function(_, parent)
		if not parent then
			expireIfCurrent()
		end
	end))
	table.insert(markConns, target.CharacterRemoving:Connect(expireIfCurrent))

	task.delay(tonumber(data.duration) or 0, expireIfCurrent)
end

powerupEffectEvent.OnClientEvent:Connect(function(powerupId, phase, data)
	if powerupId == "AugurMark" and phase == "Start" then
		startMark(data)
	elseif powerupId == "AugurMark" and phase == "End" then
		clearMark()
	elseif powerupId == "Invisibility" and phase == "Start" then
		-- The server replicated Transparency 1; a local write overrides only our
		-- OWN view (so we can still see ourselves, faintly). The server's later
		-- restore replicates over this - no local cleanup needed on "End".
		local character = localPlayer.Character
		if character then
			for _, desc in ipairs(character:GetDescendants()) do
				if desc:IsA("BasePart") and desc.Name ~= "HumanoidRootPart" then
					desc.Transparency = 0.5
				end
			end
		end
	elseif powerupId == "Flashlight" and phase == "Start" then
		flashlightActive = true
		flashlightFogEnd = (data and data.fogEnd) or CREW_FOG_END
		applyLighting()
	elseif powerupId == "Flashlight" and phase == "End" then
		flashlightActive = false
		applyLighting()
	end
end)

-- A meeting gathers everyone in one room and a match end resets the world; a mark
-- must survive neither. The server cancels its own effects on both, but the mark
-- is client-only state with no server counterpart, so these are its only cleanup.
meetingStartedEvent.OnClientEvent:Connect(clearMark)
matchEndedEvent.OnClientEvent:Connect(clearMark)

-- P fires the test lights toggle. Bound unconditionally: the client cannot read
-- DebugFlags, so the SERVER gate decides whether it does anything.
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.P then
		debugToggleLightsEvent:FireServer()
	end
end)
