--[[
	EndScreenUI.client.lua
	Full-screen match-end overlay, built entirely in code (no manually placed
	Studio GUI objects) so it stays version-controlled. Deliberately rough - a
	placeholder to be fully restyled later. No buttons, no animations.

	Lifecycle: the ScreenGui stays disabled until the server fires MatchEnded
	(winner, duration). On that event it shows the winner + a "next round"
	sub-label, then hides itself after `duration` seconds. A generation token
	guards the hide timer so a stale timer from a previous match can never hide
	a newer screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local matchEndedEvent = Remotes.Get(Remotes.Names.MatchEnded)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ============================================================
-- Build the GUI once. Stays disabled until a match actually ends.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "EndScreenGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(1, 0, 1, 0)
frame.BackgroundColor3 = Color3.new(0, 0, 0)
frame.BackgroundTransparency = 0.35
frame.Parent = screenGui

-- The verdict card, centered over the dimmed screen.
local verdictPanel = UIStyle.MakePanel(
	frame,
	UDim2.fromOffset(440, 130),
	UDim2.new(0.5, 0, 0.5, 0),
	Vector2.new(0.5, 0.5)
)

local title = UIStyle.MakeLabel(verdictPanel, "")
title.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 56)
title.Position = UDim2.new(0, UIStyle.Pad, 0, 22)
title.Font = UIStyle.HeaderFont
title.TextSize = 40
title.TextXAlignment = Enum.TextXAlignment.Center

local subLabel = UIStyle.MakeLabel(verdictPanel, "Next round starting soon...", true)
subLabel.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 24)
subLabel.Position = UDim2.new(0, UIStyle.Pad, 0, 84)
subLabel.TextXAlignment = Enum.TextXAlignment.Center

-- Incremented on every MatchEnded so a stale hide timer can't close a newer screen.
local showToken = 0

matchEndedEvent.OnClientEvent:Connect(function(winner, duration)
	if winner == "CrewWin" then
		title.Text = "CREW WINS!"
		title.TextColor3 = UIStyle.Colors.Positive
	elseif winner == "ImpostorWin" then
		title.Text = "IMPOSTORS WIN!"
		title.TextColor3 = UIStyle.Colors.Negative
	else
		title.Text = tostring(winner)
		title.TextColor3 = UIStyle.Colors.TextPrimary
	end

	screenGui.Enabled = true

	showToken = showToken + 1
	local myToken = showToken
	task.delay(duration, function()
		-- Only hide if no newer MatchEnded has shown a fresher screen since.
		if myToken == showToken then
			screenGui.Enabled = false
		end
	end)
end)
