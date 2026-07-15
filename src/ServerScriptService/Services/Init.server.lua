--[[
	Init.server.lua
	Boot script: creates all RemoteEvents, then wires client requests to the
	relevant service. Keep this file thin - it should just be plumbing.
	Actual logic lives in the individual Service modules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
Remotes.CreateAll()

local PowerupService = require(script.Parent.Services.PowerupService)
local GachaService = require(script.Parent.Services.GachaService)
local RoleManager = require(script.Parent.Services.RoleManager)

-- ============================================================
-- UsePowerup
-- ============================================================
Remotes.Get(Remotes.Names.UsePowerup).OnServerEvent:Connect(function(player, powerupId)
	local success, reason = PowerupService.TryUse(player, powerupId)
	-- (Optional) fire a client-facing result event here if you want UI feedback
	if not success then
		warn(player.Name, "failed to use", powerupId, "-", reason)
	end
end)

-- ============================================================
-- RollGacha
-- ============================================================
Remotes.Get(Remotes.Names.RollGacha).OnServerEvent:Connect(function(player, powerupId)
	local success, result, variant = GachaService.Roll(player, powerupId)
	Remotes.Get(Remotes.Names.GachaResult):FireClient(player, success, result, variant)
end)

-- ============================================================
-- Starter currency for testing (remove once real CurrencyService exists)
-- ============================================================
Players.PlayerAdded:Connect(function(player)
	player:SetAttribute("Currency", 500)
end)

print("[Suspect] Services initialized.")
