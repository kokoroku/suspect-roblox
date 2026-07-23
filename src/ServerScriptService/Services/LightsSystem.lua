--[[
	LightsSystem.lua
	Deliberately minimal lights-out stub. There is no real trigger for it yet -
	the future sabotage system becomes the real trigger for THIS exact service
	(it will call SetLightsOut); until then only the debug key (P) drives it.

	Broadcasting the boolean to everyone leaks nothing: lights-out is globally
	obvious. The ASYMMETRY (who is actually impaired) is applied client-side by
	role - see PowerupFX.client.lua.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local MatchService = require(ServerScriptService.Services.MatchService)

local LightsSystem = {}

local lightsOut = false

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

	Remotes.Get(Remotes.Names.LightsChanged):FireAllClients(state)

	for _, callback in ipairs(lightsChangedCallbacks) do
		callback(state)
	end
end

-- Every match starts with the lights on. Cycle-safe: MatchService never
-- requires LightsSystem.
MatchService.OnMatchStart(function()
	LightsSystem.SetLightsOut(false)
end)

return LightsSystem
