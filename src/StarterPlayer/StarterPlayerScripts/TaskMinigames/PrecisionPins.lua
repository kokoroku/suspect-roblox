--[[
	PrecisionPins.lua
	The "Pick the Cabinet Lock" (PrecisionPins) minigame. A marker sweeps back and
	forth across a bar; make an attempt while the marker's center sits inside the
	sweet spot to set a pin. Each pin sweeps faster with a tighter spot than the
	last. Set all PIN_COUNT pins to finish. Missing costs only that attempt - set
	pins stay set.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events). Timed color-reverts are
	    session-token guarded so no callback touches a destroyed instance.

	Input model: an attempt is F pressed (Enum.KeyCode.F via
	UserInputService.InputBegan, gameProcessed guarded) OR the bar TextButton being
	activated (a tap ANYWHERE on the bar - the mobile path). WHERE the player
	clicked or tapped is irrelevant by design; the only hit condition is whether
	the marker's center is inside the current sweet spot at the instant of the
	attempt. The hotkey connection lives in conns, made here and dropped in
	cleanup, so F is only ever captured while this task's window is open.

	Accepted current behavior: no audio, no animation beyond the flashes, no
	mobile sizing pass, Estate skin only, the sweet spots reroll every open
	(nothing persists across opens).
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local PrecisionPins = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local PIN_COUNT = 3 -- pins to set to finish
local SWEEP_SPEEDS = { 0.8, 1.1, 1.5 } -- bar-fractions/sec per pin, ping-pong (escalating)
local SPOT_SIZES = { 0.16, 0.12, 0.09 } -- sweet-spot width per pin (tighter each pin)
local SPOT_MIN = 0.08 -- sweet-spot left edge floor; the ceiling adapts to the size (0.92 - size)

local MARKER_COLOR = Color3.fromRGB(240, 240, 235) -- the sweeping marker
local SPOT_COLOR = Color3.fromRGB(235, 200, 80) -- the sweet spot
local SET_COLOR = Color3.fromRGB(100, 200, 110) -- a set pin / hit flash
local FAIL_COLOR = Color3.fromRGB(220, 70, 70) -- miss flash

-- Not core knobs:
local BAR_W, BAR_H = 340, 26 -- sweep bar size
local BAR_COLOR = Color3.fromRGB(45, 45, 50) -- dark bar track
local PIP_DARK = Color3.fromRGB(55, 55, 60) -- an unset pin pip
local FLASH_TIME = 0.25 -- seconds the sweet spot stays flashed

function PrecisionPins.Build(contentFrame, _config, onComplete)
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
	instruction.Text = "Press F when the marker is inside the zone"
	instruction.Parent = contentFrame

	-- ---- Pin pips (top-right, dark until their pin is set) ----
	local pipHolder = track(Instance.new("Frame"))
	pipHolder.AnchorPoint = Vector2.new(1, 0)
	pipHolder.Position = UDim2.new(1, -4, 0, 6)
	pipHolder.Size = UDim2.fromOffset(PIN_COUNT * 12 + (PIN_COUNT - 1) * 4, 12)
	pipHolder.BackgroundTransparency = 1
	pipHolder.ZIndex = 2
	pipHolder.Parent = contentFrame

	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.Padding = UDim.new(0, 4)
	pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pipLayout.Parent = pipHolder -- destroyed with pipHolder

	local pips = {}
	for i = 1, PIN_COUNT do
		local pip = Instance.new("Frame")
		pip.Size = UDim2.fromOffset(12, 12)
		pip.BackgroundColor3 = PIP_DARK
		pip.BorderSizePixel = 0
		pip.LayoutOrder = i
		pip.ZIndex = 2
		pip.Parent = pipHolder -- destroyed with pipHolder
		pips[i] = pip
	end

	-- ---- Sweep bar (the mobile attempt surface: an empty-text TextButton;
	-- tapping anywhere on it is an attempt - where you tap does not matter) ----
	local bar = track(Instance.new("TextButton"))
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.new(0.5, 0, 0.5, 0)
	bar.Size = UDim2.fromOffset(BAR_W, BAR_H)
	bar.BackgroundColor3 = BAR_COLOR
	bar.AutoButtonColor = false
	bar.BorderSizePixel = 0
	bar.Text = ""
	bar.Parent = contentFrame

	local barCorner = Instance.new("UICorner")
	barCorner.Parent = bar -- destroyed with the bar

	-- Sweet spot (semi-transparent; size + position change per pin).
	local spot = Instance.new("Frame")
	spot.AnchorPoint = Vector2.new(0, 0)
	spot.Size = UDim2.new(SPOT_SIZES[1], 0, 1, 0)
	spot.BackgroundColor3 = SPOT_COLOR
	spot.BackgroundTransparency = 0.4
	spot.BorderSizePixel = 0
	spot.ZIndex = 2
	spot.Parent = bar -- destroyed with the bar

	-- Marker (thin, full height, sweeps left-right).
	local marker = Instance.new("Frame")
	marker.AnchorPoint = Vector2.new(0.5, 0)
	marker.Size = UDim2.new(0, 5, 1, 0)
	marker.BackgroundColor3 = MARKER_COLOR
	marker.BorderSizePixel = 0
	marker.ZIndex = 3
	marker.Parent = bar -- destroyed with the bar

	-- ============================================================
	-- State + logic
	-- ============================================================
	local setCount = 0
	local completed = false
	local sweep = 0 -- monotonically-accumulating sweep phase (keeps the marker continuous across speed changes)
	local markerPos = 0 -- marker center as a bar fraction [0,1]
	local currentSpeed = SWEEP_SPEEDS[1]
	local currentSize = SPOT_SIZES[1]
	local spotLeft = 0

	local function applySpot()
		spot.Position = UDim2.new(spotLeft, 0, 0, 0)
	end

	-- Random left edge that always fits: [SPOT_MIN, 0.92 - currentSize].
	local function rerollSpot()
		local maxLeft = 0.92 - currentSize
		spotLeft = SPOT_MIN + math.random() * (maxLeft - SPOT_MIN)
		applySpot()
	end
	rerollSpot()

	-- Move to the next pin: new speed + tighter spot; the marker carries on from
	-- its current position (sweep phase is untouched).
	local function advancePin(pinIndex)
		currentSpeed = SWEEP_SPEEDS[pinIndex]
		currentSize = SPOT_SIZES[pinIndex]
		spot.Size = UDim2.new(currentSize, 0, 1, 0)
		rerollSpot()
	end

	local function flashSpot(color)
		session += 1
		local mySession = session
		spot.BackgroundColor3 = color
		task.delay(FLASH_TIME, function()
			if session ~= mySession then
				return
			end
			spot.BackgroundColor3 = SPOT_COLOR
		end)
	end

	-- An attempt: the ONLY hit condition is the marker's center inside the spot.
	local function attempt()
		if completed then
			return
		end
		if markerPos >= spotLeft and markerPos <= spotLeft + currentSize then
			-- Hit: set the next pin.
			setCount += 1
			pips[setCount].BackgroundColor3 = SET_COLOR
			flashSpot(SET_COLOR)
			if setCount >= PIN_COUNT then
				completed = true
				onComplete()
			else
				advancePin(setCount + 1) -- escalate; set pips never reset
			end
		else
			-- Miss: flash only. Pins are binary - a miss simply doesn't set one.
			flashSpot(FAIL_COLOR)
		end
	end

	-- Marker ping-pongs: triangle wave of the accumulated sweep phase over [0,1].
	table.insert(conns, RunService.Heartbeat:Connect(function(dt)
		if completed then
			return
		end
		sweep += currentSpeed * dt
		local phase = sweep % 2
		markerPos = phase <= 1 and phase or (2 - phase)
		marker.Position = UDim2.new(markerPos, 0, 0, 0)
	end))

	-- Attempt via F (gameProcessed guarded) or a tap anywhere on the bar.
	table.insert(conns, UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F then
			attempt()
		end
	end))

	table.insert(conns, bar.Activated:Connect(function()
		attempt()
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

return PrecisionPins
