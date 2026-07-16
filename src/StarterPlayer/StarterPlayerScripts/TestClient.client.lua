--[[
	TestClient.client.lua
	TEMPORARY - delete this once real lobby UI exists.
	Fires a gacha roll, then attempts to use whatever powerup it lands on,
	so you can confirm the whole pipeline works without any UI built yet.
	Watch the Output window while Playing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage.Modules.Remotes)

local rollEvent = Remotes.Get(Remotes.Names.RollGacha)
local resultEvent = Remotes.Get(Remotes.Names.GachaResult)
local useEvent = Remotes.Get(Remotes.Names.UsePowerup)

resultEvent.OnClientEvent:Connect(function(success, result, variant)
	print("[TestClient] Gacha result:", success, result, variant)

	if success then
		task.wait(1)
		print("[TestClient] Attempting to use SpeedBoost...")
		useEvent:FireServer("SpeedBoost")
	end
end)

task.wait(2) -- give the server a moment to finish initializing
print("[TestClient] Rolling gacha for SpeedBoost...")
rollEvent:FireServer("SpeedBoost")
