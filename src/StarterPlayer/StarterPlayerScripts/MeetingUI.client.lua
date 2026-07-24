--[[
	MeetingUI.client.lua
	Minimal functional voting UI, built entirely in code (no manually
	placed Studio GUI objects) so it stays version-controlled. Restyled against
	UIStyle - this is a cleanup pass, NOT the final meeting redesign (that comes
	later per design). Presentation only: every piece of logic, timing and remote
	handling is unchanged from the plain version.
	Also binds the emergency meeting key (M).

	UI lifecycle (matches "a round = time between meetings"):
	  - votingFrame shows ONLY while a meeting is actively being voted on.
	  - resultBanner shows the outcome of the last meeting and stays up
	    for the entire following round - it only clears/hides when the
	    NEXT meeting starts, not on a timer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)
local voteResultEvent = Remotes.Get(Remotes.Names.VoteResult)
local castVoteEvent = Remotes.Get(Remotes.Names.CastVote)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

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
-- Now a full-screen, transparent CONTAINER: toggling its Visible shows/hides the
-- dim overlay and the meeting panel together, exactly as the old panel toggled.
local votingFrame = Instance.new("Frame")
votingFrame.Visible = false
votingFrame.Size = UDim2.fromScale(1, 1)
votingFrame.Position = UDim2.fromScale(0, 0)
votingFrame.BackgroundTransparency = 1
votingFrame.Parent = screenGui

-- Full-screen dim behind the panel while a meeting is active.
local overlay = Instance.new("Frame")
overlay.Size = UDim2.fromScale(1, 1)
overlay.Position = UDim2.fromScale(0, 0)
overlay.BackgroundColor3 = Color3.new(0, 0, 0)
overlay.BackgroundTransparency = 0.45
overlay.BorderSizePixel = 0
overlay.ZIndex = 1
overlay.Parent = votingFrame

-- Centered meeting panel. Height chosen to fit header + a scrolling voter list +
-- the separated Skip button + the status line.
local PANEL_W = 520
local PANEL_H = 430
local panel = UIStyle.MakePanel(
	votingFrame,
	UDim2.fromOffset(PANEL_W, PANEL_H),
	UDim2.fromScale(0.5, 0.5),
	Vector2.new(0.5, 0.5)
)
panel.ZIndex = 2

-- Header carries the same report-vs-emergency title the code already sets; the
-- handler writes into this label's Text unchanged (grabbed back out of the strip).
local headerStrip = UIStyle.MakeHeader(panel, "Meeting")
local title = headerStrip:FindFirstChildOfClass("TextLabel")

-- Voter rows live in a scroller so any alive-count fits and a long list scrolls
-- rather than overflowing the fixed panel.
local buttonHolder = Instance.new("ScrollingFrame")
buttonHolder.Position = UDim2.new(0, UIStyle.Pad, 0, 44)
buttonHolder.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 300)
buttonHolder.BackgroundTransparency = 1
buttonHolder.BorderSizePixel = 0
buttonHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
buttonHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
buttonHolder.ScrollBarThickness = 4
buttonHolder.ZIndex = 2
buttonHolder.Parent = panel

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = buttonHolder

-- Skip sits in its own holder BELOW the rows, visually separated from the voters.
local skipHolder = Instance.new("Frame")
skipHolder.Position = UDim2.new(0, UIStyle.Pad, 0, 352)
skipHolder.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 36)
skipHolder.BackgroundTransparency = 1
skipHolder.ZIndex = 2
skipHolder.Parent = panel

local voteStatusLabel = UIStyle.MakeLabel(panel, "", true)
voteStatusLabel.Position = UDim2.new(0, UIStyle.Pad, 0, 396)
voteStatusLabel.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 24)
voteStatusLabel.TextXAlignment = Enum.TextXAlignment.Center
voteStatusLabel.ZIndex = 2

-- ---- Result banner (persists the whole round after a meeting resolves) ----
local resultBanner = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(420, 40),
	UDim2.new(0.5, 0, 0, 12),
	Vector2.new(0.5, 0)
)
resultBanner.Visible = false

local resultStroke = resultBanner:FindFirstChildOfClass("UIStroke")

local resultLabel = UIStyle.MakeLabel(resultBanner, "")
resultLabel.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, 0)
resultLabel.Position = UDim2.new(0, UIStyle.Pad, 0, 0)
resultLabel.FontFace = UIStyle.HeaderFontFace
resultLabel.TextScaled = true
resultLabel.TextXAlignment = Enum.TextXAlignment.Center

-- ---- Voting countdown bar, directly under the header ----
-- Shows the voting window the server sends on meeting start. The server enforces
-- this same duration (it auto-resolves after it), so the bar can safely deplete
-- to zero. PURELY COSMETIC: when the bar empties the client takes NO action - the
-- server owns resolution; this only visualizes the window.
local timerTrack = Instance.new("Frame")
timerTrack.Position = UDim2.new(0, UIStyle.Pad, 0, 40)
timerTrack.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 4)
timerTrack.BackgroundColor3 = UIStyle.Colors.Row
timerTrack.BorderSizePixel = 0
timerTrack.Visible = false
timerTrack.ZIndex = 2
timerTrack.Parent = panel

local timerFill = Instance.new("Frame")
timerFill.AnchorPoint = Vector2.new(0, 0)
timerFill.Position = UDim2.fromScale(0, 0)
timerFill.Size = UDim2.fromScale(1, 1)
timerFill.BackgroundColor3 = UIStyle.Colors.Accent
timerFill.BorderSizePixel = 0
timerFill.ZIndex = 3
timerFill.Parent = timerTrack

-- Bumped on every start/stop so at most one Heartbeat loop is ever live: a new
-- meeting (or the meeting display ending) invalidates the previous loop cleanly.
local timerToken = 0

local function startTimer(duration)
	timerToken += 1
	local myToken = timerToken
	timerFill.Size = UDim2.fromScale(1, 1)
	timerTrack.Visible = true
	-- Without a positive duration the bar must never count down to nothing, so it
	-- just stays full.
	if type(duration) ~= "number" or duration <= 0 then
		return
	end
	local elapsed = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if myToken ~= timerToken then
			conn:Disconnect() -- superseded by a newer meeting / a stop
			return
		end
		elapsed += dt
		local frac = math.clamp(1 - elapsed / duration, 0, 1)
		timerFill.Size = UDim2.fromScale(frac, 1)
		-- Cosmetic only: reaching zero just stops animating. The client never acts
		-- on the empty bar - the server resolves the meeting.
		if elapsed >= duration then
			conn:Disconnect()
		end
	end)
end

local function stopTimer()
	timerToken += 1 -- invalidate any running loop
	timerTrack.Visible = false
end

local hasVoted = false
-- The row the local player voted for this meeting (target or Skip), so it can be
-- tinted and later cleared.
local selectedButton = nil

local function clearButtons()
	-- Clears voter rows AND the separated Skip button, so a new meeting rebuilds
	-- both from scratch (same "rebuilt each meeting" behavior as before).
	for _, holder in ipairs({ buttonHolder, skipHolder }) do
		for _, child in ipairs(holder:GetChildren()) do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
	end
end

local function makeVoteButton(labelText, targetNameOrNil)
	-- Skip (nil target) goes to its own holder below the list; voters go in the
	-- scroller. Fire behavior is byte-for-byte the old handler.
	local isSkip = targetNameOrNil == nil
	local button = UIStyle.MakeButton(isSkip and skipHolder or buttonHolder, labelText)
	button.Size = UDim2.new(1, 0, 0, 32)
	button.ZIndex = 2
	if not isSkip then
		-- Player name reads from the left.
		button.TextXAlignment = Enum.TextXAlignment.Left
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, UIStyle.Pad)
		pad.Parent = button
	end

	button.MouseButton1Click:Connect(function()
		if hasVoted then
			return
		end
		hasVoted = true
		castVoteEvent:FireServer(targetNameOrNil)
		voteStatusLabel.Text = "Vote cast, waiting..."
		-- Tint the row we voted for. This mirrors the same client-side assumption
		-- the hasVoted guard already makes: the client treats its cast vote as
		-- landed. There is no server vote-confirmation and none is being invented.
		selectedButton = button
		UIStyle.SetButtonSelected(button, true, UIStyle.Colors.Accent)
	end)
end

-- ============================================================
-- Meeting lifecycle
-- ============================================================
meetingStartedEvent.OnClientEvent:Connect(function(reason, targetName, alivePlayerNames, duration)
	hasVoted = false
	voteStatusLabel.Text = ""
	-- Old rows are destroyed below; drop the stale selection reference with them.
	selectedButton = nil
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
	-- Start the countdown bar over the same duration the server enforces.
	startTimer(duration)
end)

voteResultEvent.OnClientEvent:Connect(function(ejectedName, ejectedRole)
	votingFrame.Visible = false
	-- Meeting display is ending: stop/hide the countdown and drop the vote tint.
	stopTimer()
	if selectedButton then
		UIStyle.SetButtonSelected(selectedButton, false)
		selectedButton = nil
	end

	if ejectedName then
		resultLabel.Text = ejectedName .. " was ejected (" .. tostring(ejectedRole) .. ")"
		-- An ejection reads Negative.
		resultLabel.TextColor3 = UIStyle.Colors.Negative
		if resultStroke then
			resultStroke.Color = UIStyle.Colors.Negative
		end
	else
		resultLabel.Text = "No one was ejected."
		-- No ejection reads Positive.
		resultLabel.TextColor3 = UIStyle.Colors.Positive
		if resultStroke then
			resultStroke.Color = UIStyle.Colors.Positive
		end
	end

	-- Stays visible for the whole round - cleared only when the next
	-- meetingStartedEvent fires, not on a timer.
	resultBanner.Visible = true
end)
