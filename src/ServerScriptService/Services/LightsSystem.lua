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

-- part -> { material = Enum.Material, color = Color3 }, captured LAZILY the
-- first time that lamp goes dark. Assumes nothing else recolors lamps at
-- runtime (accepted: nothing currently does).
local lampOriginals = {}

-- Kills or revives one tagged lamp. Safe on parts that have been destroyed or
-- taken out of the world since they were tagged.
local function applyToLamp(part, out)
	if not part or not part:IsDescendantOf(game) then
		return
	end

	if out then
		if lampOriginals[part] == nil and part:IsA("BasePart") then
			lampOriginals[part] = { material = part.Material, color = part.Color }
		end
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

-- A lamp tagged after a sabotage started must not come up lit.
CollectionService:GetInstanceAddedSignal(TAG):Connect(function(part)
	applyToLamp(part, lightsOut)
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
