--[[
	HoldFill.lua
	The "Fill the Oil Lamps" (HoldFill) minigame. Hold F (or the on-screen button)
	to fill a vertical gauge and release while the fill sits inside the green band.
	The fill ACCELERATES the longer you hold, so the tight band always rushes up at
	you - releasing early to re-ramp is often safer than riding one long hold.
	Overshoot the band and the fill drains straight to zero. Clear all LAMPS bands,
	each tighter than the last, to finish.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events). Timed color-reverts are
	    session-token guarded so no callback touches a destroyed instance.

	Hotkey: Enum.KeyCode.F via UserInputService.InputBegan/InputEnded (gameProcessed
	guarded). Those connections live in conns, made here and dropped in cleanup, so
	F is only ever captured while this task's window is open. The on-screen
	"HOLD [F]" button drives the exact same hold state - key and button are
	interchangeable at all times (mobile parity).

	Accepted current behavior: no audio, no animation beyond the fail flash, no
	mobile sizing pass, Estate skin only, each band rerolls its height (nothing
	persists across opens).
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local ClientSettings = require(script.Parent.Parent:WaitForChild("ClientSettings"))

local HoldFill = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local LAMPS = 3 -- bands to clear to finish
local FILL_START = 0.35 -- fraction/sec the gauge fills at the start of a hold
local FILL_ACCEL = 0.55 -- fraction/sec added to the fill rate per second held
local DRAIN_RATE = 0.5 -- fraction/sec it drains while not holding
local BAND_SIZES = { 0.12, 0.09, 0.06 } -- band height per lamp (tighter each lamp)
local BAND_LOW_MIN = 0.45 -- band bottom edge: uniform in [MIN, MAX], rerolled per lamp
local BAND_LOW_MAX = 0.7

local FILL_COLOR = Color3.fromRGB(235, 200, 80) -- the rising fill
local BAND_COLOR = Color3.fromRGB(100, 200, 110) -- the target band
local FAIL_COLOR = Color3.fromRGB(220, 70, 70) -- overshoot flash

-- Not core knobs:
local GAUGE_W, GAUGE_H = 60, 190 -- gauge track size
local TRACK_COLOR = Color3.fromRGB(45, 45, 50) -- dark gauge track
local PIP_DARK = Color3.fromRGB(55, 55, 60) -- an unlit lamp pip
local FAIL_FLASH = 0.3 -- seconds the gauge stays red after an overshoot

function HoldFill.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every top-level instance created inside contentFrame
	local session = 0 -- bumped by every timed revert and by cleanup

	local function track(instance)
		table.insert(instances, instance)
		return instance
	end

	-- ---- Instruction ----
	local instruction = track(Instance.new("TextLabel"))
	instruction.Size = UDim2.new(1, 0, 0, 24)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Hold F to fill - release inside the band"
	instruction.Parent = contentFrame

	-- ---- Lamp pips (top-right, dark until their lamp is cleared) ----
	local pipHolder = track(Instance.new("Frame"))
	pipHolder.AnchorPoint = Vector2.new(1, 0)
	pipHolder.Position = UDim2.new(1, -4, 0, 6)
	pipHolder.Size = UDim2.fromOffset(LAMPS * 12 + (LAMPS - 1) * 4, 12)
	pipHolder.BackgroundTransparency = 1
	pipHolder.ZIndex = 2
	pipHolder.Parent = contentFrame

	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.Padding = UDim.new(0, 4)
	pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pipLayout.Parent = pipHolder -- destroyed with pipHolder

	local pips = {}
	for i = 1, LAMPS do
		local pip = Instance.new("Frame")
		pip.Size = UDim2.fromOffset(12, 12)
		pip.BackgroundColor3 = PIP_DARK
		pip.BorderSizePixel = 0
		pip.LayoutOrder = i
		pip.ZIndex = 2
		pip.Parent = pipHolder -- destroyed with pipHolder
		pips[i] = pip
	end

	-- ---- Gauge track (center) ----
	local gauge = track(Instance.new("Frame"))
	gauge.AnchorPoint = Vector2.new(0.5, 0.5)
	gauge.Position = UDim2.new(0.5, 0, 0.45, 0)
	gauge.Size = UDim2.fromOffset(GAUGE_W, GAUGE_H)
	gauge.BackgroundColor3 = TRACK_COLOR
	gauge.BorderSizePixel = 0
	gauge.Parent = contentFrame

	-- Fill grows from the bottom; height = fill fraction.
	local fillFrame = Instance.new("Frame")
	fillFrame.AnchorPoint = Vector2.new(0.5, 1)
	fillFrame.Position = UDim2.new(0.5, 0, 1, 0)
	fillFrame.Size = UDim2.new(1, 0, 0, 0)
	fillFrame.BackgroundColor3 = FILL_COLOR
	fillFrame.BorderSizePixel = 0
	fillFrame.ZIndex = 2
	fillFrame.Parent = gauge -- destroyed with the gauge

	-- Target band (repositioned/resized per lamp). Bottom edge anchored at the
	-- bandLow fraction (Y grows downward, so scale = 1 - bandLow).
	local band = Instance.new("Frame")
	band.AnchorPoint = Vector2.new(0.5, 1)
	band.BackgroundColor3 = BAND_COLOR
	band.BackgroundTransparency = 0.5 -- semi-transparent so the fill reads through it
	band.BorderSizePixel = 0
	band.ZIndex = 3
	band.Parent = gauge -- destroyed with the gauge

	-- ---- On-screen fallback: HOLD [F] (mobile parity) ----
	local holdButton = track(Instance.new("TextButton"))
	holdButton.AnchorPoint = Vector2.new(0.5, 1)
	holdButton.Position = UDim2.new(0.5, 0, 1, -10)
	holdButton.Size = UDim2.fromOffset(200, 60)
	holdButton.BackgroundColor3 = Color3.fromRGB(70, 70, 90)
	holdButton.TextColor3 = Color3.new(1, 1, 1)
	holdButton.TextScaled = true
	holdButton.Font = Enum.Font.GothamBold
	holdButton.Text = "HOLD [" .. ClientSettings.GetKey("TaskAction").Name .. "]"
	holdButton.Parent = contentFrame

	local corner = Instance.new("UICorner")
	corner.Parent = holdButton -- destroyed with the button

	-- ============================================================
	-- State + logic
	-- ============================================================
	local fill = 0
	local heldTime = 0 -- resets to 0 on every release, so each hold re-ramps
	local lampIndex = 1
	local bandLow = 0
	local bandTop = 0
	local keyHeld = false
	local btnHeld = false
	local wasHolding = false
	local completed = false

	local function updateGauge()
		fillFrame.Size = UDim2.new(1, 0, fill, 0)
	end

	-- Reroll the current lamp's band: fresh random height, size = BAND_SIZES[i].
	local function setupBand(i)
		local size = BAND_SIZES[i]
		bandLow = BAND_LOW_MIN + math.random() * (BAND_LOW_MAX - BAND_LOW_MIN)
		bandTop = bandLow + size
		band.Position = UDim2.new(0.5, 0, 1 - bandLow, 0)
		band.Size = UDim2.new(1, 0, size, 0)
	end
	setupBand(lampIndex)

	local function flashFail()
		session += 1
		local mySession = session
		gauge.BackgroundColor3 = FAIL_COLOR
		task.delay(FAIL_FLASH, function()
			if session ~= mySession then
				return
			end
			gauge.BackgroundColor3 = TRACK_COLOR
		end)
	end

	local function lampCleared()
		pips[lampIndex].BackgroundColor3 = BAND_COLOR
		fill = 0
		heldTime = 0
		lampIndex += 1
		if lampIndex > LAMPS then
			completed = true
			onComplete()
		else
			setupBand(lampIndex)
		end
	end

	-- ---- Hold input: F key (gameProcessed guarded) + the HOLD [F] button ----
	table.insert(conns, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		-- Looked up at input time so a remap applies instantly (no reconnection).
		if input.KeyCode == ClientSettings.GetKey("TaskAction") then
			keyHeld = true
		end
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		-- Looked up at input time so a remap applies instantly (no reconnection).
		if input.KeyCode == ClientSettings.GetKey("TaskAction") then
			keyHeld = false
		end
	end))

	table.insert(conns, holdButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			btnHeld = true
		end
	end))
	table.insert(conns, holdButton.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			btnHeld = false
		end
	end))
	table.insert(conns, holdButton.MouseLeave:Connect(function()
		btnHeld = false
	end))

	table.insert(conns, RunService.Heartbeat:Connect(function(dt)
		if completed then
			return
		end
		local holding = keyHeld or btnHeld

		-- Release edge: check the band using the fill as it stood while held,
		-- BEFORE this frame's drain touches it.
		if wasHolding and not holding then
			if fill >= bandLow and fill <= bandTop then
				lampCleared()
			end
		end
		wasHolding = holding
		if completed then
			updateGauge()
			return
		end

		if holding then
			heldTime += dt
			-- Accelerating fill: the longer this single hold lasts, the faster.
			fill = math.clamp(fill + (FILL_START + FILL_ACCEL * heldTime) * dt, 0, 1)
			-- Overshoot: exceeding the band's TOP edge while holding drains to zero.
			if fill > bandTop then
				fill = 0
				heldTime = 0
				flashFail()
			end
		else
			fill = math.clamp(fill - DRAIN_RATE * dt, 0, 1)
		end
		updateGauge()
	end))

	-- ============================================================
	-- Cleanup - safe at any moment. Bump session FIRST so any in-flight revert
	-- aborts before it can touch an instance we're about to destroy.
	-- ============================================================
	return function()
		session += 1
		for _, connection in ipairs(conns) do
			connection:Disconnect()
		end
		for _, instance in ipairs(instances) do
			instance:Destroy()
		end
	end
end

return HoldFill
