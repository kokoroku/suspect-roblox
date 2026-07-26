--[[
	LightsSystem.lua
	Deliberately minimal lights-out state holder. SetLightsOut is the ONE public
	trigger (idempotent - a no-op if the state already matches): it fires the
	LightsChanged client notification and the OnLightsChanged hook flow.

	The real trigger is SabotageService (Lights sabotage on, fix station off).
	The debug key (P, gated by DebugFlags.LIGHTS_TEST_CONTROLS) is only a test
	shortcut onto the exact same call - it is not a second path.

	Broadcasting the boolean to everyone leaks nothing: lights-out is globally
	obvious. The ASYMMETRY (who is actually impaired) is applied client-side by
	role - see PowerupFX.client.lua.

	Two layers make up the effect:
	  - DIEGETIC (here, server-side, replicated): every Part tagged "RoomLamp"
	    goes dead - its light instances switch off and the part itself goes dark
	    and unlit. The world visibly darkens for EVERYONE, impostors included.
	  - ATMOSPHERIC (PowerupFX, client-side): fog and ambient decide how far each
	    role can SEE in that darkness. That layer is the only asymmetric one.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local MatchService = require(ServerScriptService.Services.MatchService)

local LightsSystem = {}

local lightsOut = false

-- Tag every lamp/fixture Part in the map with this to make it part of the
-- diegetic layer (Command Bar, once per part):
--   game:GetService("CollectionService"):AddTag(workspace.Chandelier, "RoomLamp")
local TAG = "RoomLamp"

-- The dead-lamp look while the power is out.
local DARK_LAMP_COLOR = Color3.fromRGB(45, 45, 48)

-- The Entity's Rage dims the manor one step per RAGE_STEPS threshold
-- (docs/DESIGN.md sections 3 & 9). 0 = untouched.
local rageStep = 0
local RAGE_DIM_PER_STEP = 0.15

-- part -> { material = Enum.Material, color = Color3, brightness = { [PointLight] = number } },
-- captured LAZILY the first time that lamp is touched (darkened OR dimmed).
-- Assumes nothing else recolors or re-brightens lamps at runtime (accepted:
-- nothing currently does).
local lampOriginals = {}

local function captureOriginals(part)
	if lampOriginals[part] ~= nil or not part:IsA("BasePart") then
		return
	end

	local brightness = {}
	for _, desc in ipairs(part:GetDescendants()) do
		if desc:IsA("PointLight") then
			brightness[desc] = desc.Brightness
		end
	end
	lampOriginals[part] = { material = part.Material, color = part.Color, brightness = brightness }
end

-- Applies the CURRENT rage step to one lamp's PointLights. Independent of
-- lights-out: while the lamps are snuffed their Enabled is false so this is moot,
-- and when they come back they come back at the RAGED brightness, not full.
-- The manor dims as the Entity rages; the audio/ambience layer joins in the
-- identity pass.
local function applyRageToLamp(part)
	if not part or not part:IsDescendantOf(game) or not part:IsA("BasePart") then
		return
	end

	captureOriginals(part)
	local original = lampOriginals[part]
	if not original then
		return
	end

	local scale = 1 - RAGE_DIM_PER_STEP * rageStep
	for light, base in pairs(original.brightness) do
		if light:IsDescendantOf(game) then
			light.Brightness = base * scale
		end
	end
end

-- Kills or revives one tagged lamp. Safe on parts that have been destroyed or
-- taken out of the world since they were tagged.
local function applyToLamp(part, out)
	if not part or not part:IsDescendantOf(game) then
		return
	end

	if out then
		captureOriginals(part)
		for _, desc in ipairs(part:GetDescendants()) do
			if desc:IsA("PointLight") or desc:IsA("SpotLight") or desc:IsA("SurfaceLight") then
				desc.Enabled = false
			end
		end
		if part:IsA("BasePart") then
			part.Material = Enum.Material.SmoothPlastic
			part.Color = DARK_LAMP_COLOR
		end
	else
		local original = lampOriginals[part]
		if original and part:IsA("BasePart") then
			part.Material = original.material
			part.Color = original.color
		end
		for _, desc in ipairs(part:GetDescendants()) do
			if desc:IsA("PointLight") or desc:IsA("SpotLight") or desc:IsA("SurfaceLight") then
				desc.Enabled = true
			end
		end
		-- Restore to the RAGED brightness, not full: the two layers are
		-- independent, and fixing the fuse box must not undo the Entity's Rage.
		applyRageToLamp(part)
	end
end

function LightsSystem.IsLightsOut()
	return lightsOut
end

-- Callbacks fired when lights-out state changes. Same one-directional hook
-- pattern as MeetingSystem.OnMeetingStart, so PowerupService can react without
-- LightsSystem ever requiring it.
local lightsChangedCallbacks = {}

function LightsSystem.OnLightsChanged(callback)
	table.insert(lightsChangedCallbacks, callback)
end

function LightsSystem.SetLightsOut(state)
	if lightsOut == state then
		return
	end
	lightsOut = state

	-- The diegetic layer: the lamps themselves. This is what makes the world
	-- visibly darken for EVERYONE, impostors included - the client fog layer only
	-- decides how far each role can see once it is dark.
	for _, lamp in ipairs(CollectionService:GetTagged(TAG)) do
		applyToLamp(lamp, state)
	end

	Remotes.Get(Remotes.Names.LightsChanged):FireAllClients(state)

	for _, callback in ipairs(lightsChangedCallbacks) do
		callback(state)
	end
end

-- The Entity's Rage dim. step is 0..3 (0 restores every lamp to its captured base
-- brightness). RitualService is the only caller; it pushes on every lit-brazier
-- change and resets to 0 at match start.
function LightsSystem.SetRageDim(step)
	rageStep = math.clamp(step or 0, 0, 3)

	for _, lamp in ipairs(CollectionService:GetTagged(TAG)) do
		applyRageToLamp(lamp)
	end
end

-- A lamp tagged after a sabotage started must not come up lit, and must join the
-- current rage step rather than burning at full brightness.
CollectionService:GetInstanceAddedSignal(TAG):Connect(function(part)
	applyToLamp(part, lightsOut)
	if not lightsOut then
		applyRageToLamp(part)
	end
end)

CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(part)
	lampOriginals[part] = nil
end)

-- Ghosts and late joiners need the current state; they missed the broadcast.
Players.PlayerAdded:Connect(function(player)
	Remotes.Get(Remotes.Names.LightsChanged):FireClient(player, lightsOut)
end)

-- Every match starts with the lights on. Cycle-safe: MatchService never
-- requires LightsSystem.
MatchService.OnMatchStart(function()
	LightsSystem.SetLightsOut(false)
end)

return LightsSystem
