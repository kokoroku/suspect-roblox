--[[
	KillInput.client.lua
	Real gameplay input (not a throwaway test script): press F near another
	player to attempt a kill. Server validates everything (role, distance,
	cooldown) - this script just finds a nearby target and fires the
	remote. No "am I allowed to kill" logic here on purpose; the server
	is the only source of truth for whether it actually works.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local attemptKillEvent = Remotes.Get(Remotes.Names.AttemptKill)

local localPlayer = Players.LocalPlayer
local KILL_KEY = Enum.KeyCode.F
local SEARCH_RANGE = 10 -- slightly generous on purpose; real check is server-side

local function findNearestTarget()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local nearest, nearestDistance = nil, SEARCH_RANGE
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= localPlayer and player.Character then
			local otherRoot = player.Character:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local distance = (otherRoot.Position - root.Position).Magnitude
				if distance < nearestDistance then
					nearest = player
					nearestDistance = distance
				end
			end
		end
	end

	return nearest
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode ~= KILL_KEY then return end

	local target = findNearestTarget()
	if target then
		attemptKillEvent:FireServer(target)
	end
end)
