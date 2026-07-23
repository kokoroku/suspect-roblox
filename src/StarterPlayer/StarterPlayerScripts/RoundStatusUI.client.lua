--[[
	RoundStatusUI.client.lua
	Top-center round-status banner: waiting-for-players count, intermission
	countdown, and a spectator notice while a match you're not in is running.
	Built entirely in code (no manually placed Studio GUI objects) so it stays
	version-controlled. Deliberately rough - restyled in the UI rehaul pass.

	Driven purely by the RoundStatus remote. The "Ended" state is intentionally
	blank here - EndScreenUI owns the end screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local roundStatusEvent = Remotes.Get(Remotes.Names.RoundStatus)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RoundStatusGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local label = Instance.new("TextLabel")
label.AnchorPoint = Vector2.new(0.5, 0)
label.Position = UDim2.new(0.5, 0, 0, 8)
label.Size = UDim2.new(0, 420, 0, 28)
label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
label.BackgroundTransparency = 0.3
label.TextColor3 = Color3.new(1, 1, 1)
label.Font = Enum.Font.Gotham
label.TextScaled = true
label.Text = ""
label.Visible = false
label.Parent = screenGui

-- Remembered from a personal InProgress snapshot; cleared when we get a body.
local spectator = false

roundStatusEvent.OnClientEvent:Connect(function(data)
	if data.state == "Waiting" then
		label.Text = "Waiting for players (" .. tostring(data.playersPresent) .. "/" .. tostring(data.playersNeeded) .. ")"
		label.Visible = true
	elseif data.state == "Intermission" then
		label.Text = "Match starting in " .. tostring(data.secondsLeft) .. "s"
		label.Visible = true
	elseif data.state == "InProgress" then
		if data.spectator then
			spectator = true
		end
		if spectator then
			label.Text = "Match in progress - you'll join the next round"
			label.Visible = true
		else
			label.Visible = false
		end
	else
		-- "Ended" (EndScreenUI owns the end screen) or anything unexpected.
		label.Visible = false
	end
end)

localPlayer.CharacterAdded:Connect(function()
	-- We've been spawned into the world, so we're no longer a spectator. The
	-- next non-spectator status will hide the banner.
	spectator = false
end)
