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
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local roundStatusEvent = Remotes.Get(Remotes.Names.RoundStatus)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RoundStatusGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- Top-center pill. SabotageBanner sits directly beneath it.
local panel = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(420, 30),
	UDim2.new(0.5, 0, 0, 10),
	Vector2.new(0.5, 0)
)
panel.Visible = false

local label = UIStyle.MakeLabel(panel, "")
label.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, 0)
label.Position = UDim2.new(0, UIStyle.Pad, 0, 0)
label.TextXAlignment = Enum.TextXAlignment.Center
-- Floats over the 3D world, so it takes the stronger banner outline.
label.TextStrokeTransparency = UIStyle.BannerStrokeTransparency

-- Remembered from a personal InProgress snapshot; cleared when we get a body.
local spectator = false

roundStatusEvent.OnClientEvent:Connect(function(data)
	if data.state == "Waiting" then
		label.Text = "Waiting for players (" .. tostring(data.playersPresent) .. "/" .. tostring(data.playersNeeded) .. ")"
		panel.Visible = true
	elseif data.state == "Intermission" then
		label.Text = "Match starting in " .. tostring(data.secondsLeft) .. "s"
		panel.Visible = true
	elseif data.state == "InProgress" then
		if data.spectator then
			spectator = true
		end
		if spectator then
			label.Text = "Match in progress - you'll join the next round"
			panel.Visible = true
		else
			panel.Visible = false
		end
	else
		-- "Ended" (EndScreenUI owns the end screen) or anything unexpected.
		panel.Visible = false
	end
end)

localPlayer.CharacterAdded:Connect(function()
	-- We've been spawned into the world, so we're no longer a spectator. The
	-- next non-spectator status will hide the banner.
	spectator = false
end)
