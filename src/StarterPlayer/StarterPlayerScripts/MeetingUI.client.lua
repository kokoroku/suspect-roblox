--[[
	MeetingUI.client.lua
	Minimal functional voting UI, built entirely in code (no manually
	placed Studio GUI objects) so it stays version-controlled. Not
	styled/polished yet - that's a later art pass, this just needs to work.
	Also binds the emergency meeting key (M).

	UI lifecycle (matches "a round = time between meetings"):
	  - votingFrame shows ONLY while a meeting is actively being voted on.
	  - resultBanner shows the outcome of the last meeting and stays up
	    for the entire following round - it only clears/hides when the
	    NEXT meeting starts, not on a timer.
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
-- Build the GUI once. screenGui itself stays enabled once a meeting has
-- ever happened - votingFrame and resultBanner control what's actually
-- visible, independently of each other.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MeetingGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

-- ---- Voting frame (visible only during an active meeting) ----
local votingFrame = Instance.new("Frame")
votingFrame.Visible = false
votingFrame.Size = UDim2.new(0, 300, 0, 420)
votingFrame.Position = UDim2.new(0.5, -150, 0.5, -210)
votingFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
votingFrame.Parent = screenGui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 40)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.new(1, 1, 1)
title.TextScaled = true
title.Font = Enum.Font.GothamBold
title.Text = "Meeting"
title.Parent = votingFrame

local buttonHolder = Instance.new("Frame")
buttonHolder.Size = UDim2.new(1, -10, 1, -50)
buttonHolder.Position = UDim2.new(0, 5, 0, 45)
buttonHolder.BackgroundTransparency = 1
buttonHolder.Parent = votingFrame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = buttonHolder

local voteStatusLabel = Instance.new("TextLabel")
voteStatusLabel.Size = UDim2.new(1, 0, 0, 30)
voteStatusLabel.Position = UDim2.new(0, 0, 1, -30)
voteStatusLabel.BackgroundTransparency = 1
voteStatusLabel.TextColor3 = Color3.new(1, 1, 1)
voteStatusLabel.TextScaled = true
voteStatusLabel.Font = Enum.Font.Gotham
voteStatusLabel.Text = ""
voteStatusLabel.Parent = votingFrame

-- ---- Result banner (persists the whole round after a meeting resolves) ----
local resultBanner = Instance.new("Frame")
resultBanner.Visible = false
resultBanner.Size = UDim2.new(0, 320, 0, 36)
resultBanner.Position = UDim2.new(0.5, -160, 0, 10)
resultBanner.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
resultBanner.BackgroundTransparency = 0.2
resultBanner.Parent = screenGui

local resultLabel = Instance.new("TextLabel")
resultLabel.Size = UDim2.new(1, 0, 1, 0)
resultLabel.BackgroundTransparency = 1
resultLabel.TextColor3 = Color3.new(1, 1, 1)
resultLabel.TextScaled = true
resultLabel.Font = Enum.Font.Gotham
resultLabel.Text = ""
resultLabel.Parent = resultBanner

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
		voteStatusLabel.Text = "Vote cast, waiting..."
	end)
end

-- ============================================================
-- Meeting lifecycle
-- ============================================================
meetingStartedEvent.OnClientEvent:Connect(function(reason, targetName, alivePlayerNames, _duration)
	hasVoted = false
	voteStatusLabel.Text = ""
	clearButtons()

	title.Text = (reason == "Emergency") and "Emergency Meeting" or ("Body Reported: " .. tostring(targetName))

	for _, name in ipairs(alivePlayerNames) do
		if name ~= localPlayer.Name then
			makeVoteButton(name, name)
		end
	end
	makeVoteButton("Skip Vote", nil)

	-- New round starting: clear last round's result banner, show voting.
	resultBanner.Visible = false
	votingFrame.Visible = true
	screenGui.Enabled = true
end)

voteResultEvent.OnClientEvent:Connect(function(ejectedName, ejectedRole)
	votingFrame.Visible = false

	if ejectedName then
		resultLabel.Text = ejectedName .. " was ejected (" .. tostring(ejectedRole) .. ")"
	else
		resultLabel.Text = "No one was ejected."
	end

	-- Stays visible for the whole round - cleared only when the next
	-- meetingStartedEvent fires, not on a timer.
	resultBanner.Visible = true
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
