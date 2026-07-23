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

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 80)
title.Position = UDim2.new(0, 0, 0.4, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextScaled = true
title.Text = ""
title.Parent = frame

local subLabel = Instance.new("TextLabel")
subLabel.Size = UDim2.new(1, 0, 0, 30)
subLabel.Position = UDim2.new(0, 0, 0.4, 80)
subLabel.BackgroundTransparency = 1
subLabel.Font = Enum.Font.Gotham
subLabel.TextColor3 = Color3.new(1, 1, 1)
subLabel.TextScaled = true
subLabel.Text = "Next round starting soon..."
subLabel.Parent = frame

-- Incremented on every MatchEnded so a stale hide timer can't close a newer screen.
local showToken = 0

matchEndedEvent.OnClientEvent:Connect(function(winner, duration)
	if winner == "CrewWin" then
		title.Text = "CREW WINS!"
		title.TextColor3 = Color3.fromRGB(120, 220, 120)
	elseif winner == "ImpostorWin" then
		title.Text = "IMPOSTORS WIN!"
		title.TextColor3 = Color3.fromRGB(220, 80, 80)
	else
		title.Text = tostring(winner)
		title.TextColor3 = Color3.new(1, 1, 1)
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
