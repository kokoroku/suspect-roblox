--[[
	RitualUI.client.lua
	The Banishment's presence on screen (docs/DESIGN.md section 3): brazier
	progress, the armed state, and the Convergence channel. Built entirely in code
	from UIStyle (no manually placed Studio GUI objects) so it stays
	version-controlled. Deliberately rough - restyled in the identity pass.

	Third in the top-center stack: RoundStatus (y 10), SabotageBanner (y 52), this.

	Driven purely by the RitualStatus remote - the server broadcasts on every state
	change and twice a second while armed, so nothing here ticks or polls. Everyone
	sees the same thing, Vessel included: lit braziers are physically visible in the
	world, so there is nothing to hide.

	The Desecrate omen rides in on SabotageStatus rather than RitualStatus, because
	it IS the sabotage broadcast - a one-shot "the Entity stirs" announcement with
	no state behind it. It takes the pill over for a moment and hands it back.

	EndScreenUI still owns the actual end screen; "THE BANISHMENT" here is only the
	beat before it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)

local ritualStatusEvent = Remotes.Get(Remotes.Names.RitualStatus)
local sabotageStatusEvent = Remotes.Get(Remotes.Names.SabotageStatus)
local matchEndedEvent = Remotes.Get(Remotes.Names.MatchEnded)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- How long the Desecrate omen holds the pill, and how long "THE BANISHMENT"
-- shows before it steps aside for the end screen.
local OMEN_SECONDS = 2
local COMPLETE_SECONDS = 3

local BAR_HEIGHT = 4

-- RichText needs a hex string, so derive one from the style module rather than
-- hardcoding a second copy of the color - the art pass re-skins UIStyle only.
local function toHex(color)
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end
local ACCENT_HEX = toHex(UIStyle.Colors.Accent)

-- ============================================================
-- Build the GUI once.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RitualUIGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local panel = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(420, 30),
	UDim2.new(0.5, 0, 0, 94),
	Vector2.new(0.5, 0)
)
panel.Visible = false

local panelStroke = panel:FindFirstChildOfClass("UIStroke")

local label = UIStyle.MakeLabel(panel, "")
label.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, 0)
label.Position = UDim2.new(0, UIStyle.Pad, 0, 0)
label.FontFace = UIStyle.HeaderFontFace
label.TextXAlignment = Enum.TextXAlignment.Center
label.RichText = true
-- Floats over the 3D world, so it takes the stronger banner outline.
label.TextStrokeTransparency = UIStyle.BannerStrokeTransparency

-- ---- The channel block, directly under the pill. Armed state only. ----
local channelFrame = Instance.new("Frame")
channelFrame.Size = UDim2.fromOffset(420, 24)
channelFrame.Position = UDim2.new(0.5, 0, 0, 128)
channelFrame.AnchorPoint = Vector2.new(0.5, 0)
channelFrame.BackgroundTransparency = 1
channelFrame.Visible = false
channelFrame.Parent = screenGui

local track = Instance.new("Frame")
track.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)
track.BackgroundColor3 = UIStyle.Colors.Row
track.BorderSizePixel = 0
track.Parent = channelFrame

local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(0, 2)
trackCorner.Parent = track

local fill = Instance.new("Frame")
fill.Size = UDim2.new(0, 0, 1, 0)
fill.BackgroundColor3 = UIStyle.Colors.Positive
fill.BorderSizePixel = 0
fill.Parent = track

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 2)
fillCorner.Parent = fill

local channelersLabel = UIStyle.MakeLabel(channelFrame, "", true)
channelersLabel.Size = UDim2.new(1, 0, 0, 16)
channelersLabel.Position = UDim2.new(0, 0, 0, BAR_HEIGHT + 2)
channelersLabel.TextSize = 12
channelersLabel.TextXAlignment = Enum.TextXAlignment.Center
channelersLabel.TextStrokeTransparency = UIStyle.BannerStrokeTransparency

-- ============================================================
-- State
-- ============================================================
local status = nil -- the last RitualStatus payload, or nil for "nothing to show"
-- The omen borrows the pill; while it is up, render() leaves the display alone.
local omenActive = false
local omenToken = 0
-- completeScheduled: a hide is already pending. completeShown: the brief moment
-- has passed, so the pill steps aside for the end screen.
local completeScheduled = false
local completeShown = false

local function setStroke(color, thickness)
	if panelStroke then
		panelStroke.Color = color
		panelStroke.Thickness = thickness
	end
end

local function hideAll()
	panel.Visible = false
	channelFrame.Visible = false
end

local function render()
	if omenActive then
		return -- the omen owns the pill for its window
	end

	local data = status
	if not data then
		hideAll()
		return
	end

	if data.complete then
		if completeShown then
			hideAll() -- the beat has passed; the end screen has the floor
			return
		end
		setStroke(UIStyle.Colors.Accent, 2)
		label.Text = "THE BANISHMENT"
		label.TextColor3 = UIStyle.Colors.Positive
		panel.Visible = true
		channelFrame.Visible = false
		return
	end

	if data.armed then
		setStroke(UIStyle.Colors.Accent, 2)
		label.Text = "THE RITUAL IS ARMED - hold the circle"
		label.TextColor3 = UIStyle.Colors.TextPrimary
		panel.Visible = true

		-- Set DIRECTLY, never tweened: a death-interrupt decays progress by a third
		-- in one broadcast, and that has to read as a drop, not a graceful slide.
		local progress = math.clamp(tonumber(data.channelProgress) or 0, 0, 1)
		fill.Size = UDim2.new(progress, 0, 1, 0)
		channelersLabel.Text = string.format(
			"channelers %d/%d",
			tonumber(data.channelersPresent) or 0,
			tonumber(data.channelRequired) or 0
		)
		channelFrame.Visible = true
		return
	end

	local lit = tonumber(data.lit) or 0
	if lit <= 0 then
		-- Nothing lit and not armed: the ritual has not visibly begun.
		hideAll()
		return
	end

	setStroke(UIStyle.Colors.Stroke, 1)
	label.Text = string.format(
		'Braziers <font color="%s">%d/%d</font>',
		ACCENT_HEX,
		lit,
		tonumber(data.threshold) or 0
	)
	label.TextColor3 = UIStyle.Colors.TextPrimary
	panel.Visible = true
	channelFrame.Visible = false
end

-- ============================================================
-- Remote-driven state
-- ============================================================
ritualStatusEvent.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" then
		return
	end
	status = data

	if data.complete then
		if not completeScheduled then
			completeScheduled = true
			task.delay(COMPLETE_SECONDS, function()
				completeShown = true
				render()
			end)
		end
	else
		-- A fresh match's first broadcast resets the pair together.
		completeScheduled = false
		completeShown = false
	end

	render()
end)

-- The Desecrate omen. EVERYONE gets this - that is the point of it: the Vessel
-- pays for the brazier by announcing that something took it.
sabotageStatusEvent.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" or data.rejected or data.type ~= "Desecrate" then
		return
	end

	omenActive = true
	omenToken += 1
	local myToken = omenToken

	setStroke(UIStyle.Colors.Negative, 2)
	label.Text = "The Entity stirs..."
	label.TextColor3 = UIStyle.Colors.Negative
	-- Forced visible: the omen must show even when the snuffed brazier was the
	-- last one and the pill would otherwise be hiding itself.
	panel.Visible = true
	channelFrame.Visible = false

	task.delay(OMEN_SECONDS, function()
		if omenToken ~= myToken then
			return -- a newer omen owns the pill now
		end
		omenActive = false
		render()
	end)
end)

matchEndedEvent.OnClientEvent:Connect(function()
	-- The end screen owns the screen. This also covers every match that ends by a
	-- route OTHER than the Banishment (parity, a verdict, Manifestation): the
	-- server sends no ritual reset broadcast, so without this the last brazier
	-- count would burn over the end screen and into the next round.
	status = nil
	omenActive = false
	omenToken += 1
	completeScheduled = false
	completeShown = false
	hideAll()
end)
