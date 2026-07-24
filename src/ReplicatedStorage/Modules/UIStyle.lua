--[[
	UIStyle.lua
	Shared UI style + tiny builder library. Every code-built screen that belongs
	to the QoL pass (bottom bar, hub window) pulls its colors, fonts and widget
	construction from here.

	Rough-but-CONSISTENT on purpose. The point is not that this looks good yet -
	it is that the art pass re-skins THIS file rather than hunting colors and
	fonts through every script. Add a value here before hardcoding one anywhere.

	No requires of its own, so it stays cycle-free and safe to pull in from
	client or server.
]]

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local UIStyle = {}

UIStyle.Colors = {
	Bg = Color3.fromRGB(16, 16, 22),
	Panel = Color3.fromRGB(28, 28, 38),
	Row = Color3.fromRGB(50, 50, 66),
	RowHover = Color3.fromRGB(68, 68, 90),
	Stroke = Color3.fromRGB(95, 95, 125),
	Accent = Color3.fromRGB(255, 200, 60),
	Positive = Color3.fromRGB(90, 210, 120),
	Negative = Color3.fromRGB(230, 70, 80),
	TextPrimary = Color3.fromRGB(245, 245, 250),
	TextDim = Color3.fromRGB(170, 170, 190),
	Selected = Color3.fromRGB(100, 200, 110),
	RarityCommon = Color3.fromRGB(180, 180, 180),
	RarityRare = Color3.fromRGB(80, 140, 220),
	RarityEpic = Color3.fromRGB(170, 90, 220),
	TaskShort = Color3.fromRGB(120, 170, 255),
	TaskLong = Color3.fromRGB(255, 165, 80),
}

-- Montserrat ships WITH the engine, so this is not a marketplace dependency and
-- needs no asset upload. FontFace and the legacy .Font property cannot be mixed
-- on one instance: whichever is assigned last wins, so every builder below sets
-- FontFace only.
local MONTSERRAT = "rbxasset://fonts/families/Montserrat.json"
UIStyle.HeaderFontFace = Font.new(MONTSERRAT, Enum.FontWeight.Bold)
UIStyle.BodyFontFace = Font.new(MONTSERRAT, Enum.FontWeight.SemiBold)

-- Legacy enum equivalents, kept ONLY so older callers that still assign .Font
-- keep working. Anything new should use the FontFace values above.
UIStyle.HeaderFont = Enum.Font.GothamBold
UIStyle.BodyFont = Enum.Font.Gotham

UIStyle.Corner = 8 -- UICorner radius, pixels
UIStyle.Pad = 8 -- standard inner padding, pixels

-- How much of a dragged panel must stay on screen, in pixels.
local MIN_ON_SCREEN = 40

-- Text outlines. Every builder below stamps the standard values onto the text it
-- creates, so panel text keeps a subtle edge without anyone thinking about it.
-- Elements that float over the 3D WORLD (the top-center banners) override with
-- the Banner value, which is the same outline pushed harder - they have to stay
-- readable against whatever the map is doing behind them.
UIStyle.TextStrokeColor = Color3.fromRGB(0, 0, 0)
UIStyle.TextStrokeTransparency = 0.35
UIStyle.BannerStrokeTransparency = 0.2

-- ============================================================
-- Builders. Each parents the instance and returns it.
-- ============================================================

-- A window/section surface: Panel fill, rounded, thin stroke.
function UIStyle.MakePanel(parent, size, position, anchorPoint)
	local frame = Instance.new("Frame")
	frame.Size = size or UDim2.fromOffset(200, 200)
	frame.Position = position or UDim2.new(0.5, 0, 0.5, 0)
	frame.AnchorPoint = anchorPoint or Vector2.new(0, 0)
	frame.BackgroundColor3 = UIStyle.Colors.Panel
	frame.BorderSizePixel = 0
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, UIStyle.Corner)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = UIStyle.Colors.Stroke
	stroke.Parent = frame

	return frame
end

-- A clickable row/button. Hover is SELECTION-AWARE via the "Selected" attribute
-- (see SetButtonSelected): a selected button keeps its selection color and just
-- goes see-through on hover, so hovering can never wipe the state color.
function UIStyle.MakeButton(parent, text)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(120, 32)
	button.BackgroundColor3 = UIStyle.Colors.Row
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.FontFace = UIStyle.BodyFontFace
	button.TextColor3 = UIStyle.Colors.TextPrimary
	button.TextStrokeColor3 = UIStyle.TextStrokeColor
	button.TextStrokeTransparency = UIStyle.TextStrokeTransparency
	button.TextSize = 14
	button.Text = text or ""
	button:SetAttribute("Selected", false)
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, UIStyle.Corner)
	corner.Parent = button

	button.MouseEnter:Connect(function()
		if button:GetAttribute("Selected") then
			button.BackgroundTransparency = 0.35
		else
			button.BackgroundColor3 = UIStyle.Colors.RowHover
		end
	end)
	button.MouseLeave:Connect(function()
		if button:GetAttribute("Selected") then
			button.BackgroundTransparency = 0
		else
			button.BackgroundColor3 = UIStyle.Colors.Row
		end
	end)

	return button
end

-- Mark a MakeButton selected (or not). Selected buttons paint selectedColor at
-- full opacity; deselected ones go back to the standard Row fill.
--
-- Text readability: a rarity-tinted row on a bright selection fill is unreadable,
-- so selection stashes the row's own text color, switches to TextPrimary with a
-- harder outline, and puts the stashed color back on deselect.
function UIStyle.SetButtonSelected(button, selected, selectedColor)
	button:SetAttribute("Selected", selected and true or false)
	button.BackgroundTransparency = 0
	if selected then
		if button:GetAttribute("UnselectedTextColor") == nil then
			button:SetAttribute("UnselectedTextColor", button.TextColor3)
		end
		button.BackgroundColor3 = selectedColor or UIStyle.Colors.Selected
		button.TextColor3 = UIStyle.Colors.TextPrimary
		button.TextStrokeTransparency = 0.15
	else
		local stored = button:GetAttribute("UnselectedTextColor")
		if stored then
			button.TextColor3 = stored
			button:SetAttribute("UnselectedTextColor", nil)
		end
		button.BackgroundColor3 = UIStyle.Colors.Row
		button.TextStrokeTransparency = UIStyle.TextStrokeTransparency
	end
end

-- Plain text. dim = true for secondary/explanatory lines.
function UIStyle.MakeLabel(parent, text, dim)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 20)
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.FontFace = UIStyle.BodyFontFace
	label.TextColor3 = dim and UIStyle.Colors.TextDim or UIStyle.Colors.TextPrimary
	label.TextStrokeColor3 = UIStyle.TextStrokeColor
	label.TextStrokeTransparency = UIStyle.TextStrokeTransparency
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = text or ""
	label.Parent = parent
	return label
end

-- Top strip of a panel: title on the left, optional X on the right. Returns the
-- strip frame so callers can position content beneath it.
function UIStyle.MakeHeader(panel, titleText, onClose)
	local strip = Instance.new("Frame")
	strip.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 28)
	strip.Position = UDim2.new(0, UIStyle.Pad, 0, UIStyle.Pad)
	strip.BackgroundTransparency = 1
	strip.Parent = panel

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -36, 1, 0)
	title.BackgroundTransparency = 1
	title.FontFace = UIStyle.HeaderFontFace
	title.TextColor3 = UIStyle.Colors.TextPrimary
	title.TextStrokeColor3 = UIStyle.TextStrokeColor
	title.TextStrokeTransparency = UIStyle.TextStrokeTransparency
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = titleText or ""
	title.Parent = strip

	-- Accent underline under the title - the same treatment the hub's active tab
	-- uses, so "this is the live thing" reads the same way everywhere.
	local underline = Instance.new("Frame")
	underline.AnchorPoint = Vector2.new(0, 1)
	underline.Position = UDim2.new(0, 0, 1, 0)
	underline.Size = UDim2.new(1, -36, 0, 2)
	underline.BackgroundColor3 = UIStyle.Colors.Accent
	underline.BorderSizePixel = 0
	underline.Parent = strip

	if onClose then
		local closeButton = UIStyle.MakeButton(strip, "X")
		closeButton.AnchorPoint = Vector2.new(1, 0.5)
		closeButton.Position = UDim2.new(1, 0, 0.5, 0)
		closeButton.Size = UDim2.fromOffset(28, 24)
		closeButton.FontFace = UIStyle.HeaderFontFace
		closeButton.MouseButton1Click:Connect(onClose)
	end

	return strip
end

-- ============================================================
-- Window behavior helpers. Both return a cleanup function, and both survive the
-- panel being destroyed mid-drag (every frame re-checks the panel is still in
-- the tree before touching it).
--
-- MOVE and RESIZE are MUTUALLY EXCLUSIVE by construction, which is the whole
-- point of this layer: a press is a resize if and only if it lands within EDGE
-- pixels of a border, and a move if and only if it does not. There are no
-- invisible handle frames to overlap the content, so a press that begins in the
-- interior can never become a resize, a press on a border can never become a
-- move, and a press that never moves is just a click that resizes by zero.
-- ============================================================
-- Claude Code: these are the ONLY cursor strings in the codebase - if one does
-- not resolve in-game, swap it here and nowhere else.
local CURSOR_DEFAULT = "" -- empty string restores the default arrow
local CURSOR_EW = "rbxasset://SystemCursors/SizeEW"
local CURSOR_NS = "rbxasset://SystemCursors/SizeNS"
local CURSOR_NWSE = "rbxasset://SystemCursors/SizeNWSE" -- NW <-> SE
local CURSOR_NESW = "rbxasset://SystemCursors/SizeNESW" -- NE <-> SW

local EDGE = 8 -- px band inward/outward from a border that counts as that edge
local HIGHLIGHT_THICKNESS = 2
local HIGHLIGHT_CORNER_LEN = 18 -- bar length on each arm of a corner highlight

local ZONE_CURSOR = {
	N = CURSOR_NS, S = CURSOR_NS,
	E = CURSOR_EW, W = CURSOR_EW,
	NW = CURSOR_NWSE, SE = CURSOR_NWSE,
	NE = CURSOR_NESW, SW = CURSOR_NESW,
}

-- Shared guards so the two helpers never fight over one gesture.
local activeResizePanel = nil
local activeMovePanel = nil

-- Which border zone (px, py) falls in for this panel: "N"/"S"/"E"/"W" or a
-- corner, else nil for the interior or well outside. Corners win over edges.
local function edgeAt(panel, px, py)
	local pos, size = panel.AbsolutePosition, panel.AbsoluteSize
	local left, top = pos.X, pos.Y
	local right, bottom = left + size.X, top + size.Y

	-- Outside the panel plus its edge band on either axis: not an edge at all.
	if px < left - EDGE or px > right + EDGE or py < top - EDGE or py > bottom + EDGE then
		return nil
	end

	local nearLeft = math.abs(px - left) <= EDGE
	local nearRight = math.abs(px - right) <= EDGE
	local nearTop = math.abs(py - top) <= EDGE
	local nearBottom = math.abs(py - bottom) <= EDGE

	if nearTop and nearLeft then
		return "NW"
	elseif nearTop and nearRight then
		return "NE"
	elseif nearBottom and nearLeft then
		return "SW"
	elseif nearBottom and nearRight then
		return "SE"
	elseif nearTop then
		return "N"
	elseif nearBottom then
		return "S"
	elseif nearLeft then
		return "W"
	elseif nearRight then
		return "E"
	end
	return nil
end

-- Press-and-drag anywhere on dragHandle to move panel. Pointer positions are
-- used AS-IS and only ever as deltas, so the GUI inset never enters the math.
-- Clamped so at least MIN_ON_SCREEN pixels of the panel stay reachable.
function UIStyle.MakeDraggable(panel, dragHandle)
	local conns = {}
	local dragging = false
	-- The grab point and the panel's position AT the grab, both captured on press.
	-- Everything during the drag is measured against these two, never recomputed
	-- from where the pointer happens to be.
	local dragStartPointer = Vector2.new()
	local dragStartPos = panel.Position

	local function isPointer(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	local function isMovement(input)
		return input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
	end

	table.insert(conns, dragHandle.InputBegan:Connect(function(input)
		if not isPointer(input) then
			return
		end
		-- Never start a move that belongs to a resize: a press inside the border
		-- band (a corner of the header row, say) is the resize layer's gesture.
		if activeResizePanel or edgeAt(panel, input.Position.X, input.Position.Y) then
			return
		end
		dragging = true
		activeMovePanel = panel
		dragStartPointer = Vector2.new(input.Position.X, input.Position.Y)
		dragStartPos = panel.Position
	end))

	local function stopDragging()
		dragging = false
		if activeMovePanel == panel then
			activeMovePanel = nil
		end
	end

	table.insert(conns, dragHandle.InputEnded:Connect(function(input)
		if isPointer(input) then
			stopDragging()
		end
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then
			stopDragging()
		end
	end))

	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not dragging or activeResizePanel or not isMovement(input) then
			return
		end
		local parent = panel.Parent
		if not parent then
			stopDragging() -- destroyed mid-drag
			return
		end

		-- Move by the DELTA FROM THE GRAB POINT, added to the position the panel
		-- had when it was grabbed. That is what makes the window track the cursor
		-- 1:1 with no jump: deriving the position from the absolute pointer instead
		-- would yank the panel's anchor under the cursor on the first frame, which
		-- is exactly the snap this replaces.
		local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStartPointer
		local offsetX = dragStartPos.X.Offset + delta.X
		local offsetY = dragStartPos.Y.Offset + delta.Y

		-- Where that lands the panel's top-left, in absolute pixels.
		local parentPos, parentSize = parent.AbsolutePosition, parent.AbsoluteSize
		local panelSize, anchor = panel.AbsoluteSize, panel.AnchorPoint
		local left = parentPos.X + dragStartPos.X.Scale * parentSize.X + offsetX - anchor.X * panelSize.X
		local top = parentPos.Y + dragStartPos.Y.Scale * parentSize.Y + offsetY - anchor.Y * panelSize.Y

		-- Clamp the top-left, then fold the correction back into the offsets.
		local clampedLeft = math.clamp(
			left,
			parentPos.X - panelSize.X + MIN_ON_SCREEN,
			parentPos.X + parentSize.X - MIN_ON_SCREEN
		)
		local clampedTop = math.clamp(
			top,
			parentPos.Y - panelSize.Y + MIN_ON_SCREEN,
			parentPos.Y + parentSize.Y - MIN_ON_SCREEN
		)

		panel.Position = UDim2.new(
			dragStartPos.X.Scale,
			offsetX + (clampedLeft - left),
			dragStartPos.Y.Scale,
			offsetY + (clampedTop - top)
		)
	end))

	local function cleanup()
		stopDragging()
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		conns = {}
	end

	table.insert(conns, panel.Destroying:Connect(cleanup))

	return cleanup
end

-- ============================================================
-- Edge/corner resizing, the way a desktop window does it - but with NO handle
-- frames. Hit-testing is done against the panel's live AbsolutePosition/Size,
-- so nothing invisible sits on top of the content to swallow clicks (which is
-- what made a plain click resize the window before).
--
-- Hover an edge -> resize cursor + a 2px Accent highlight on exactly that edge.
-- Press an edge -> resize. Press the interior -> the press falls straight
-- through to whatever is under it (buttons, the header's drag). See the
-- mutual-exclusivity note at the top of this section.
-- ============================================================
function UIStyle.MakeResizable(panel, minSize, maxSize)
	local conns = {}

	-- nil on the server (no LocalPlayer); cursor work is then simply skipped.
	local localPlayer = Players.LocalPlayer
	local mouse = localPlayer and localPlayer:GetMouse()

	local activeZone = nil -- the zone being dragged, nil when not resizing
	local hovering = false -- do WE currently own the cursor?
	local pointerStart = Vector2.new()
	local startAbsSize = panel.AbsoluteSize
	local startPosition = panel.Position

	-- ---- Edge highlight: one reusable child, two bars (an edge lights one, a
	-- corner lights both, short). Never input-catching, always on top. ----
	local highlight = Instance.new("Frame")
	highlight.Name = "ResizeHighlight"
	highlight.Size = UDim2.new(1, 0, 1, 0)
	highlight.BackgroundTransparency = 1
	highlight.Active = false
	highlight.ZIndex = 50
	highlight.Visible = false
	highlight.Parent = panel

	local function makeBar()
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = UIStyle.Colors.Accent
		bar.BorderSizePixel = 0
		bar.Active = false
		bar.ZIndex = 50
		bar.Visible = false
		bar.Parent = highlight
		return bar
	end
	local barH, barV = makeBar(), makeBar()

	local function showHighlight(zone)
		if not zone then
			highlight.Visible = false
			barH.Visible = false
			barV.Visible = false
			return
		end

		local hasTop = string.find(zone, "N") ~= nil
		local hasBottom = string.find(zone, "S") ~= nil
		local hasLeft = string.find(zone, "W") ~= nil
		local hasRight = string.find(zone, "E") ~= nil
		local isCorner = #zone == 2

		highlight.Visible = true

		barH.Visible = hasTop or hasBottom
		if barH.Visible then
			local y = hasTop and 0 or 1
			local x = hasLeft and 0 or (hasRight and 1 or 0.5)
			barH.AnchorPoint = Vector2.new(x, y)
			barH.Position = UDim2.new(x, 0, y, 0)
			barH.Size = isCorner and UDim2.fromOffset(HIGHLIGHT_CORNER_LEN, HIGHLIGHT_THICKNESS)
				or UDim2.new(1, 0, 0, HIGHLIGHT_THICKNESS)
		end

		barV.Visible = hasLeft or hasRight
		if barV.Visible then
			local x = hasLeft and 0 or 1
			local y = hasTop and 0 or (hasBottom and 1 or 0.5)
			barV.AnchorPoint = Vector2.new(x, y)
			barV.Position = UDim2.new(x, 0, y, 0)
			barV.Size = isCorner and UDim2.fromOffset(HIGHLIGHT_THICKNESS, HIGHLIGHT_CORNER_LEN)
				or UDim2.new(0, HIGHLIGHT_THICKNESS, 1, 0)
		end
	end

	local function setCursor(icon)
		if mouse then
			mouse.Icon = icon
		end
	end

	-- Only react while the panel is actually on screen - a closed window must not
	-- keep answering to the patch of screen it used to occupy.
	local function panelActive()
		if not panel.Parent or not panel.Visible then
			return false
		end
		local layer = panel:FindFirstAncestorWhichIsA("LayerCollector")
		return layer == nil or layer.Enabled
	end

	local function clearHover()
		showHighlight(nil)
		if hovering then
			hovering = false
			setCursor(CURSOR_DEFAULT)
		end
	end

	local function isPointer(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	local function isMovement(input)
		return input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
	end

	local function stopResizing()
		if activeZone then
			activeZone = nil
			if activeResizePanel == panel then
				activeResizePanel = nil
			end
		end
	end

	-- ---- Press: an edge press claims the gesture, an interior press is ignored
	-- entirely so it reaches the button/header underneath. ----
	table.insert(conns, UserInputService.InputBegan:Connect(function(input)
		if not isPointer(input) or activeResizePanel or activeMovePanel then
			return
		end
		if not panelActive() then
			return
		end

		local zone = edgeAt(panel, input.Position.X, input.Position.Y)
		if not zone then
			return -- interior or elsewhere: not ours
		end

		activeZone = zone
		activeResizePanel = panel
		pointerStart = Vector2.new(input.Position.X, input.Position.Y)
		startAbsSize = panel.AbsoluteSize
		startPosition = panel.Position
		setCursor(ZONE_CURSOR[zone])
		hovering = true
		showHighlight(zone)
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if isPointer(input) then
			stopResizing()
		end
	end))

	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not isMovement(input) then
			return
		end

		if not panel.Parent then
			stopResizing() -- destroyed mid-gesture
			return
		end

		-- ---- Hover feedback (never while any gesture is running) ----
		if not activeZone then
			if activeResizePanel or activeMovePanel or not panelActive() then
				clearHover()
				return
			end
			local zone = edgeAt(panel, input.Position.X, input.Position.Y)
			showHighlight(zone)
			if zone then
				hovering = true
				setCursor(ZONE_CURSOR[zone])
			elseif hovering then
				hovering = false
				setCursor(CURSOR_DEFAULT)
			end
			return
		end

		-- ---- Live resize ----
		local delta = Vector2.new(input.Position.X, input.Position.Y) - pointerStart
		local hasTop = string.find(activeZone, "N") ~= nil
		local hasBottom = string.find(activeZone, "S") ~= nil
		local hasLeft = string.find(activeZone, "W") ~= nil
		local hasRight = string.find(activeZone, "E") ~= nil

		local width, height = startAbsSize.X, startAbsSize.Y
		-- W/N grow as the pointer moves NEGATIVE, hence the subtraction.
		if hasRight then
			width = startAbsSize.X + delta.X
		elseif hasLeft then
			width = startAbsSize.X - delta.X
		end
		if hasBottom then
			height = startAbsSize.Y + delta.Y
		elseif hasTop then
			height = startAbsSize.Y - delta.Y
		end

		width = math.clamp(width, minSize.X, maxSize.X)
		height = math.clamp(height, minSize.Y, maxSize.Y)

		-- Move the anchor so the border NOT being dragged stays put. Derived from
		-- the CLAMPED size, so hitting min/max parks the panel instead of letting
		-- the fixed border drift.
		local deltaWidth = width - startAbsSize.X
		local deltaHeight = height - startAbsSize.Y
		local anchor = panel.AnchorPoint
		local offsetX, offsetY = 0, 0

		if hasRight then
			offsetX = anchor.X * deltaWidth
		elseif hasLeft then
			offsetX = -(1 - anchor.X) * deltaWidth
		end
		if hasBottom then
			offsetY = anchor.Y * deltaHeight
		elseif hasTop then
			offsetY = -(1 - anchor.Y) * deltaHeight
		end

		panel.Size = UDim2.fromOffset(width, height)
		panel.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + offsetX,
			startPosition.Y.Scale,
			startPosition.Y.Offset + offsetY
		)
	end))

	local function cleanup()
		stopResizing()
		clearHover()
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		conns = {}
		if highlight.Parent then
			highlight:Destroy()
		end
	end

	table.insert(conns, panel.Destroying:Connect(cleanup))

	return cleanup
end

return UIStyle
