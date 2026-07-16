--[[
	MeetingUI.client.lua
	Minimal functional voting UI, built entirely in code (no manually
	placed Studio GUI objects) so it stays version-controlled. Not
	styled/polished yet - that's a later art pass, this just needs to work.
	Also binds the emergency meeting key (M).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)
local voteResultEvent = Remotes.Get(Remotes.Names.VoteResult)
local castVoteEvent = Remotes.Get(Remotes.Names.CastVote)
local callMeetingEvent = Remotes.Get(Remotes.Names.CallMeeting)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local EMERGENCY_KEY = Enum.KeyCode.M

-- ============================================================
-- Build the GUI once, keep it hidden until a meeting starts
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MeetingGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 300, 0, 420)
frame.Position = UDim2.new(0.5, -150, 0.5, -210)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.Parent = screenGui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 40)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.new(1, 1, 1)
title.TextScaled = true
title.Font = Enum.Font.GothamBold
title.Text = "Meeting"
title.Parent = frame

local buttonHolder = Instance.new("Frame")
buttonHolder.Size = UDim2.new(1, -10, 1, -90)
buttonHolder.Position = UDim2.new(0, 5, 0, 45)
buttonHolder.BackgroundTransparency = 1
buttonHolder.Parent = frame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = buttonHolder

local resultLabel = Instance.new("TextLabel")
resultLabel.Size = UDim2.new(1, 0, 0, 40)
resultLabel.Position = UDim2.new(0, 0, 1, -40)
resultLabel.BackgroundTransparency = 1
resultLabel.TextColor3 = Color3.new(1, 1, 1)
resultLabel.TextScaled = true
resultLabel.Font = Enum.Font.Gotham
resultLabel.Text = ""
resultLabel.Parent = screenGui

local hasVoted = false

local function clearButtons()
	for _, child in ipairs(buttonHolder:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

local function makeVoteButton(labelText, targetNameOrNil)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 0, 32)
	button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.Gotham
	button.TextScaled = true
	button.Text = labelText
	button.Parent = buttonHolder

	button.MouseButton1Click:Connect(function()
		if hasVoted then
			return
		end
		hasVoted = true
		castVoteEvent:FireServer(targetNameOrNil)
		resultLabel.Text = "Vote cast, waiting..."
	end)
end

-- ============================================================
-- Meeting lifecycle
-- ============================================================
meetingStartedEvent.OnClientEvent:Connect(function(reason, targetName, alivePlayerNames, _duration)
	hasVoted = false
	resultLabel.Text = ""
	clearButtons()

	title.Text = (reason == "Emergency") and "Emergency Meeting" or ("Body Reported: " .. tostring(targetName))

	for _, name in ipairs(alivePlayerNames) do
		if name ~= localPlayer.Name then
			makeVoteButton(name, name)
		end
	end
	makeVoteButton("Skip Vote", nil)

	screenGui.Enabled = true
end)

voteResultEvent.OnClientEvent:Connect(function(ejectedName, ejectedRole)
	if ejectedName then
		resultLabel.Text = ejectedName .. " was ejected (" .. tostring(ejectedRole) .. ")"
	else
		resultLabel.Text = "No one was ejected."
	end

	task.delay(4, function()
		screenGui.Enabled = false
	end)
end)

-- ============================================================
-- Emergency meeting key
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= EMERGENCY_KEY then
		return
	end
	callMeetingEvent:FireServer()
end)
