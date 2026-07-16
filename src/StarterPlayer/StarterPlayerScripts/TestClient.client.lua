--[[
	TestClient.client.lua
	TEMPORARY - delete this once real lobby UI exists.
	Full pipeline test: roll gacha -> equip loadout -> use powerup.
	Watch the Output window while Playing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Modules.Remotes)

local rollEvent = Remotes.Get(Remotes.Names.RollGacha)
local gachaResultEvent = Remotes.Get(Remotes.Names.GachaResult)
local setLoadoutEvent = Remotes.Get(Remotes.Names.SetLoadout)
local loadoutResultEvent = Remotes.Get(Remotes.Names.LoadoutResult)
local useEvent = Remotes.Get(Remotes.Names.UsePowerup)

loadoutResultEvent.OnClientEvent:Connect(function(success, reason)
	print("[TestClient] Loadout set:", success, reason)

	if success then
		task.wait(1)
		print("[TestClient] Attempting to use SpeedBoost...")
		useEvent:FireServer("SpeedBoost")
	end
end)

gachaResultEvent.OnClientEvent:Connect(function(success, result, variant)
	print("[TestClient] Gacha result:", success, result, variant)

	if success then
		task.wait(1)
		print("[TestClient] Equipping SpeedBoost as loadout slot 1...")
		setLoadoutEvent:FireServer({ "SpeedBoost" })
	end
end)

task.wait(2) -- give the server a moment to finish initializing
print("[TestClient] Rolling gacha for SpeedBoost...")
rollEvent:FireServer("SpeedBoost")