--[[
	SettingsUI.client.lua
	The settings window and its bottom-left cog button. Reads/writes ClientSettings
	(the shared module) and nothing else.

	Sections: Audio (master volume slider), Keybinds (remappable rows + the fixed
	world-interact row), Interface (reset UI layout), Accessibility (reduce effects).

	Layout: ONE scroll surface under the header - every section flows in a single
	UIListLayout, so nothing clips and everything is reachable by scrolling.
	Fonts: Montserrat (UIStyle) for all words; the pixel PressStart2P font appears
	in EXACTLY one place - the key text inside the keycap chips.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))
local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- The ONE pixel-font use in this file: the letter inside a keycap chip.
local PIXEL_FONT = "rbxasset://fonts/families/PressStart2P.json"
local PIXEL_FONTFACE = Font.new(PIXEL_FONT)
local NEAR_WHITE = Color3.fromRGB(235, 235, 240)
local BLACK = Color3.fromRGB(0, 0, 0)

local WINDOW_SIZE = UDim2.fromOffset(400, 560)
-- Opens centered-left: pinned to the left third, vertically centered.
local WINDOW_POSITION = UDim2.new(0.28, 0, 0.5, 0)

local CHIP_MIN = 30 -- keycap min square side
local CHIP_MAX = 64 -- keycap widens up to here for longer names

-- Short display for a keycap, same mapping the HUD badges use: digit keys collapse
-- to their number, single letters pass through, anything else falls back to Name.
local DIGIT_NAMES = {
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
	Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
}
local function shortKeyName(keyCode)
	return DIGIT_NAMES[keyCode.Name] or keyCode.Name
end

-- Chip width for a name: min square for 1 char, widening with length up to CHIP_MAX.
local function chipWidth(text)
	return math.clamp(#text * 12 + 16, CHIP_MIN, CHIP_MAX)
end

-- ============================================================
-- Root GUI.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SettingsGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = true
screenGui.Parent = playerGui

-- ---- Bottom-left cog button ----
-- Emoji renders via Roblox's emoji fallback regardless of font; if it shows as a
-- placeholder box in-game, swap this Text to "Set" (this one string).
local cogButton = UIStyle.MakeButton(screenGui, "\u{2699}\u{FE0F}")
cogButton.Name = "SettingsCog"
cogButton.AnchorPoint = Vector2.new(0, 1)
cogButton.Position = UDim2.new(0, 10, 1, -10)
cogButton.Size = UDim2.fromOffset(40, 40)
cogButton.TextSize = 20

-- ---- Window: fixed size, draggable by the header, NO resize of any kind ----
local window = UIStyle.MakePanel(screenGui, WINDOW_SIZE, WINDOW_POSITION, Vector2.new(0.5, 0.5))
window.Visible = false
-- Sinks clicks so a click on the panel can't reach a world ProximityPrompt.
window.Active = true

local function setOpen(open)
	window.Visible = open
end

local headerStrip = UIStyle.MakeHeader(window, "Settings", function()
	setOpen(false)
end)

-- Drag by the header only. Fixed size: no MakeResizable, no edge handles anywhere.
UIStyle.MakeDraggable(window, headerStrip)

cogButton.MouseButton1Click:Connect(function()
	setOpen(not window.Visible)
end)

-- Force-hidden on meeting start, like the hub.
meetingStartedEvent.OnClientEvent:Connect(function()
	setOpen(false)
end)

-- ============================================================
-- The ONE scroll surface: everything under the header lives in this list.
-- ============================================================
local content = Instance.new("ScrollingFrame")
content.Position = UDim2.new(0, UIStyle.Pad, 0, 44)
content.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, -(44 + UIStyle.Pad))
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.CanvasSize = UDim2.new(0, 0, 0, 0)
content.AutomaticCanvasSize = Enum.AutomaticSize.Y
content.ScrollBarThickness = 4
content.Parent = window

local contentLayout = Instance.new("UIListLayout")
contentLayout.Padding = UDim.new(0, 8)
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Parent = content

-- Right padding keeps rows (and chips) clear of the scrollbar; bottom padding so
-- the last section isn't flush against the edge.
local contentPad = Instance.new("UIPadding")
contentPad.PaddingRight = UDim.new(0, 12)
contentPad.PaddingBottom = UDim.new(0, 8)
contentPad.Parent = content

local layoutOrder = 0
local function nextOrder()
	layoutOrder += 1
	return layoutOrder
end

-- Small all-caps section label (Montserrat header, Accent).
local function makeSectionLabel(text)
	local label = UIStyle.MakeLabel(content, text)
	label.Size = UDim2.new(1, 0, 0, 18)
	label.FontFace = UIStyle.HeaderFontFace
	label.TextSize = 13
	label.TextColor3 = UIStyle.Colors.Accent
	label.LayoutOrder = nextOrder()
	return label
end

-- Dimmed helper line under a control.
local function makeHelpLine(text)
	local label = UIStyle.MakeLabel(content, text, true)
	label.Size = UDim2.new(1, 0, 0, 16)
	label.TextSize = 12
	label.LayoutOrder = nextOrder()
	return label
end

-- A plain row container to hold controls side by side.
local function makeRow(height)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, height)
	row.BackgroundTransparency = 1
	row.LayoutOrder = nextOrder()
	row.Parent = content
	return row
end

-- A full-square keycap chip: hard edges (no UICorner), a COMPLETE four-sided
-- UIStroke, dark fill, and the key text in the pixel font. Right-aligned in its
-- parent row. Returns the chip frame, its letter label, and its stroke.
local function makeKeycap(parent)
	local cap = Instance.new("Frame")
	cap.AnchorPoint = Vector2.new(1, 0.5)
	cap.Position = UDim2.new(1, -2, 0.5, 0)
	cap.Size = UDim2.fromOffset(CHIP_MIN, CHIP_MIN)
	cap.BackgroundColor3 = UIStyle.Colors.Bg
	cap.BorderSizePixel = 0
	cap.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = NEAR_WHITE
	stroke.Parent = cap -- default ApplyStrokeMode = Border, so all four sides

	local letter = Instance.new("TextLabel")
	letter.BackgroundTransparency = 1
	letter.Size = UDim2.fromScale(1, 1)
	letter.FontFace = PIXEL_FONTFACE -- the ONLY pixel-font instance in this file
	letter.TextScaled = true
	letter.TextColor3 = UIStyle.Colors.Accent
	letter.TextStrokeColor3 = BLACK
	letter.TextStrokeTransparency = 0
	letter.Text = ""
	letter.Parent = cap

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 5)
	pad.PaddingBottom = UDim.new(0, 5)
	pad.PaddingLeft = UDim.new(0, 5)
	pad.PaddingRight = UDim.new(0, 5)
	pad.Parent = letter

	return cap, letter, stroke
end

-- ============================================================
-- a) AUDIO - master volume slider
-- ============================================================
makeSectionLabel("AUDIO")

local volumeRow = makeRow(28)

local volumeName = UIStyle.MakeLabel(volumeRow, "Master volume")
volumeName.Size = UDim2.fromOffset(120, 28)

local TRACK_WIDTH = 200
local HANDLE_SIZE = 16

local sliderTrack = Instance.new("Frame")
sliderTrack.AnchorPoint = Vector2.new(0, 0.5)
sliderTrack.Position = UDim2.new(0, 124, 0.5, 0)
sliderTrack.Size = UDim2.fromOffset(TRACK_WIDTH, 4)
sliderTrack.BackgroundColor3 = UIStyle.Colors.Row
sliderTrack.BorderSizePixel = 0
sliderTrack.Parent = volumeRow

local sliderFill = Instance.new("Frame")
sliderFill.Size = UDim2.fromScale(0, 1)
sliderFill.BackgroundColor3 = UIStyle.Colors.Accent
sliderFill.BorderSizePixel = 0
sliderFill.Parent = sliderTrack

local sliderHandle = Instance.new("Frame")
sliderHandle.AnchorPoint = Vector2.new(0.5, 0.5)
sliderHandle.Size = UDim2.fromOffset(HANDLE_SIZE, HANDLE_SIZE)
sliderHandle.Position = UDim2.new(0, 0, 0.5, 0)
sliderHandle.BackgroundColor3 = UIStyle.Colors.Accent
sliderHandle.BorderSizePixel = 0
sliderHandle.ZIndex = 2
sliderHandle.Parent = sliderTrack

local handleCorner = Instance.new("UICorner")
handleCorner.CornerRadius = UDim.new(1, 0)
handleCorner.Parent = sliderHandle

local percentLabel = UIStyle.MakeLabel(volumeRow, "100%")
percentLabel.AnchorPoint = Vector2.new(1, 0.5)
percentLabel.Position = UDim2.new(1, 0, 0.5, 0)
percentLabel.Size = UDim2.fromOffset(44, 28)
percentLabel.TextXAlignment = Enum.TextXAlignment.Right

-- Paints the handle/fill/percent to a 0..1 value (no write-back).
local function renderVolume(v)
	sliderHandle.Position = UDim2.new(v, 0, 0.5, 0)
	sliderFill.Size = UDim2.fromScale(v, 1)
	percentLabel.Text = string.format("%d%%", math.floor(v * 100 + 0.5))
end

renderVolume(ClientSettings.GetVolume())

-- Drag the handle, same delta pattern as MakeDraggable: capture the grab, move by
-- pointer delta, clamp to the track, write the resulting fraction to settings.
do
	local dragging = false
	local dragStartX = 0
	local startFraction = 0

	local function isPointer(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end
	local function isMovement(input)
		return input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
	end

	sliderHandle.InputBegan:Connect(function(input)
		if not isPointer(input) then
			return
		end
		dragging = true
		dragStartX = input.Position.X
		startFraction = ClientSettings.GetVolume()
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging or not isMovement(input) then
			return
		end
		local delta = input.Position.X - dragStartX
		local fraction = math.clamp(startFraction + delta / TRACK_WIDTH, 0, 1)
		ClientSettings.SetVolume(fraction)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then
			dragging = false
		end
	end)
end

-- ============================================================
-- b) KEYBINDS - rows flow directly in the main list (no nested scroller)
-- ============================================================
makeSectionLabel("KEYBINDS")

-- One capture at a time across all rows.
local capturingAction = nil
-- action -> refresh function, so Changed can repaint a row live.
local rowRefreshers = {}
-- Every remappable row's handle, so a new capture can cancel the previous one and
-- the key listener can resolve the active row.
local keybindRows = {}

local KEYBOARD_EMOJI = "\u{2328}\u{FE0F}" -- shown while listening; swap to "..." if it renders as a box

local function cancelActiveCapture()
	for _, r in ipairs(keybindRows) do
		if r.isCapturing() then
			r.cancel()
		end
	end
end

local function makeKeybindRow(action)
	local baseName = ClientSettings.DisplayNames[action] or action

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 34)
	row.BackgroundTransparency = 1
	row.LayoutOrder = nextOrder()
	row.Parent = content

	local name = UIStyle.MakeLabel(row, baseName)
	name.Size = UDim2.new(1, -76, 1, 0)
	name.Position = UDim2.new(0, 2, 0, 0)

	-- Brief red notice (Reserved / InUse), sitting just left of the chip.
	local notice = UIStyle.MakeLabel(row, "", true)
	notice.AnchorPoint = Vector2.new(1, 0.5)
	notice.Position = UDim2.new(1, -74, 0.5, 0)
	notice.Size = UDim2.fromOffset(120, 18)
	notice.TextSize = 12
	notice.TextXAlignment = Enum.TextXAlignment.Right
	notice.TextColor3 = UIStyle.Colors.Negative
	notice.Visible = false

	local cap, letter, stroke = makeKeycap(row)

	-- Transparent click target over the chip (keeps the chip itself a plain Frame).
	local clickBtn = Instance.new("TextButton")
	clickBtn.AnchorPoint = Vector2.new(1, 0.5)
	clickBtn.Position = UDim2.new(1, -2, 0.5, 0)
	clickBtn.Size = UDim2.fromOffset(CHIP_MIN, CHIP_MIN)
	clickBtn.BackgroundTransparency = 1
	clickBtn.AutoButtonColor = false
	clickBtn.Text = ""
	clickBtn.ZIndex = 3
	clickBtn.Parent = row

	local fxToken = 0 -- guards the timed flash-then-restore sequences
	local pulseTween = nil

	-- Show the resting key: short name + auto-width chip.
	local function showKey()
		local text = shortKeyName(ClientSettings.GetKey(action))
		local w = chipWidth(text)
		letter.Text = text
		cap.Size = UDim2.fromOffset(w, CHIP_MIN)
		clickBtn.Size = UDim2.fromOffset(w, CHIP_MIN)
	end
	showKey()

	local function stopPulse()
		if pulseTween then
			pulseTween:Cancel()
			pulseTween = nil
		end
		stroke.Transparency = 0
	end

	local function startPulse()
		stopPulse()
		pulseTween = TweenService:Create(
			stroke,
			TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = 0.6 }
		)
		pulseTween:Play()
	end

	local noticeToken = 0
	local function flashNotice(text)
		notice.Text = text
		notice.Visible = true
		noticeToken += 1
		local myToken = noticeToken
		task.delay(1.5, function()
			if myToken == noticeToken then
				notice.Visible = false
			end
		end)
	end

	-- Enter listening state: Accent + pulsing stroke, keyboard glyph, label suffix.
	local function enterCapture()
		capturingAction = action
		fxToken += 1
		notice.Visible = false
		stroke.Color = UIStyle.Colors.Accent
		letter.TextColor3 = UIStyle.Colors.TextPrimary
		letter.Text = KEYBOARD_EMOJI
		cap.Size = UDim2.fromOffset(34, CHIP_MIN)
		clickBtn.Size = UDim2.fromOffset(34, CHIP_MIN)
		name.Text = baseName .. "  (press a key)"
		startPulse()
	end

	-- Return the chip to its resting look showing whatever key is currently bound.
	local function restoreResting()
		stopPulse()
		stroke.Color = NEAR_WHITE
		letter.TextColor3 = UIStyle.Colors.Accent
		name.Text = baseName
		showKey()
	end

	local function cancelCapture()
		if capturingAction == action then
			capturingAction = nil
		end
		fxToken += 1 -- supersede any pending flash
		restoreResting()
	end

	-- SetKey already applied the new binding; flash Positive, then settle.
	local function onSuccess()
		if capturingAction == action then
			capturingAction = nil
		end
		fxToken += 1
		local myToken = fxToken
		stopPulse()
		name.Text = baseName
		letter.TextColor3 = UIStyle.Colors.Accent
		showKey() -- the NEW key
		stroke.Color = UIStyle.Colors.Positive
		task.delay(0.35, function()
			if myToken == fxToken then
				stroke.Color = NEAR_WHITE
			end
		end)
	end

	-- Rejected: old binding stands. Flash Negative + row notice, then settle.
	local function onReject(reason)
		if capturingAction == action then
			capturingAction = nil
		end
		fxToken += 1
		local myToken = fxToken
		stopPulse()
		name.Text = baseName
		letter.TextColor3 = UIStyle.Colors.Accent
		showKey() -- unchanged old key
		stroke.Color = UIStyle.Colors.Negative
		flashNotice(reason == "Reserved" and "Reserved" or "In use")
		task.delay(0.6, function()
			if myToken == fxToken then
				stroke.Color = NEAR_WHITE
			end
		end)
	end

	-- Live repaint from Changed elsewhere, but never while this row is listening.
	rowRefreshers[action] = function()
		if capturingAction ~= action then
			showKey()
		end
	end

	clickBtn.MouseButton1Click:Connect(function()
		if capturingAction == action then
			return -- already listening on this row
		end
		cancelActiveCapture() -- starting here cancels any other row's capture
		enterCapture()
	end)

	return {
		action = action,
		isCapturing = function()
			return capturingAction == action
		end,
		cancel = cancelCapture,
		success = onSuccess,
		reject = onReject,
	}
end

for _, action in ipairs(ClientSettings.KeybindOrder) do
	table.insert(keybindRows, makeKeybindRow(action))
end

-- Fixed, non-interactive world-interact row: dimmed, but the SAME full-square chip.
do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 34)
	row.BackgroundTransparency = 1
	row.LayoutOrder = nextOrder()
	row.Parent = content

	local name = UIStyle.MakeLabel(row, "Interact (world) - fixed", true)
	name.Size = UDim2.new(1, -76, 1, 0)
	name.Position = UDim2.new(0, 2, 0, 0)

	local _, letter = makeKeycap(row)
	letter.Text = "E"
	letter.TextColor3 = UIStyle.Colors.TextDim -- dimmed to read as non-interactive
end

makeHelpLine("E is reserved for world interactions")

-- The capture key listener: the next keyboard press while listening becomes the
-- binding. Escape cancels. gameProcessed is deliberately NOT gated here so any key
-- can be bound. One row listens at a time.
UserInputService.InputBegan:Connect(function(input)
	if capturingAction == nil then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local capturingRow
	for _, r in ipairs(keybindRows) do
		if r.isCapturing() then
			capturingRow = r
			break
		end
	end
	if not capturingRow then
		return
	end

	if input.KeyCode == Enum.KeyCode.Escape then
		capturingRow.cancel()
		return
	end

	local ok, reason = ClientSettings.SetKey(capturingRow.action, input.KeyCode)
	if ok then
		capturingRow.success()
	else
		capturingRow.reject(reason)
	end
end)

-- ============================================================
-- c) INTERFACE - reset UI layout
-- ============================================================
makeSectionLabel("INTERFACE")

local resetRow = makeRow(32)
local resetButton = UIStyle.MakeButton(resetRow, "Reset UI layout")
resetButton.Size = UDim2.fromOffset(150, 32)
resetButton.MouseButton1Click:Connect(function()
	ClientSettings.FireResetLayout()
end)

makeHelpLine("Returns moved windows to their default spots")

-- ============================================================
-- d) ACCESSIBILITY - reduce screen effects toggle
-- ============================================================
makeSectionLabel("ACCESSIBILITY")

local reduceRow = makeRow(32)
local reduceName = UIStyle.MakeLabel(reduceRow, "Reduce screen effects")
reduceName.Size = UDim2.new(1, -70, 1, 0)

local reduceToggle = UIStyle.MakeButton(reduceRow, "OFF")
reduceToggle.AnchorPoint = Vector2.new(1, 0.5)
reduceToggle.Position = UDim2.new(1, 0, 0.5, 0)
reduceToggle.Size = UDim2.fromOffset(60, 28)

local function renderReduce(on)
	reduceToggle.Text = on and "ON" or "OFF"
	UIStyle.SetButtonSelected(reduceToggle, on, UIStyle.Colors.Positive)
end
renderReduce(ClientSettings.GetReduceEffects())

reduceToggle.MouseButton1Click:Connect(function()
	ClientSettings.SetReduceEffects(not ClientSettings.GetReduceEffects())
end)

makeHelpLine("Disables kill flash and camera punch")

-- ============================================================
-- Live updates from ClientSettings.Changed (edits from anywhere).
-- ============================================================
ClientSettings.Changed.Event:Connect(function(settingName)
	if settingName == "Volume" then
		renderVolume(ClientSettings.GetVolume())
	elseif settingName == "ReduceEffects" then
		renderReduce(ClientSettings.GetReduceEffects())
	elseif rowRefreshers[settingName] then
		rowRefreshers[settingName]()
	end
end)
