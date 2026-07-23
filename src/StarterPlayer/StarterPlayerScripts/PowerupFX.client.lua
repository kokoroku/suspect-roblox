--[[
	PowerupFX.client.lua
	The ONE client-side owner of Lighting changes plus self-only powerup visuals.
	Single owner on purpose - nothing else should write to the shared Lighting
	service, so there is never a race over fog/ambient.

	The lights-out darkening is a STUB stand-in for the future sabotage system:
	when sabotage exists it will drive LightsChanged server-side, and this file's
	reaction is already the finished client half.

	Built entirely in code, deliberately rough - full styling comes in the UI
	rehaul pass.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local roleAssignedEvent = Remotes.Get(Remotes.Names.RoleAssigned)
local lightsChangedEvent = Remotes.Get(Remotes.Names.LightsChanged)
local powerupEffectEvent = Remotes.Get(Remotes.Names.PowerupEffect)
local debugToggleLightsEvent = Remotes.Get(Remotes.Names.DebugToggleLights)

local localPlayer = Players.LocalPlayer

local DARK_FOG_END = 25
local DARK_AMBIENT = Color3.fromRGB(8, 8, 12)

-- Snapshot the map's lit look once, so we can always restore exactly it.
local originalFogEnd = Lighting.FogEnd
local originalAmbient = Lighting.Ambient

local ownRole = nil
local lightsOut = false
local flashlightActive = false
local flashlightRange = DARK_FOG_END

-- Impostors always see the lit values (unimpaired in the dark - the genre's
-- standard asymmetry). Non-impostors get darkness while lights-out, except that
-- an active own-Flashlight widens the fog to its range instead of DARK_FOG_END.
local function applyLighting()
	if ownRole == "Impostor" or not lightsOut then
		Lighting.FogEnd = originalFogEnd
		Lighting.Ambient = originalAmbient
		return
	end

	Lighting.Ambient = DARK_AMBIENT
	Lighting.FogEnd = flashlightActive and flashlightRange or DARK_FOG_END
end

roleAssignedEvent.OnClientEvent:Connect(function(role)
	ownRole = role
	applyLighting()
end)

lightsChangedEvent.OnClientEvent:Connect(function(state)
	lightsOut = state
	applyLighting()
end)

powerupEffectEvent.OnClientEvent:Connect(function(powerupId, phase, data)
	if powerupId == "Invisibility" and phase == "Start" then
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
		flashlightRange = (data and data.range) or DARK_FOG_END
		applyLighting()
	elseif powerupId == "Flashlight" and phase == "End" then
		flashlightActive = false
		applyLighting()
	end
end)

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
