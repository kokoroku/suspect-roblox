--[[
	FixSwitches.lua
	The "Reset the Fuse Box" fix minigame - the repair for the Lights sabotage.
	A row of breakers wired together: pressing one flips it AND its immediate
	neighbors (the Lights Out puzzle). Get every breaker back on.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events). The success flash is
	    session-token guarded so no callback touches a destroyed instance.

	CLICK-ONLY - NO HOTKEY. Fix minigames must NEVER bind F (or any world action
	key) the way task minigames do: an impostor is allowed to open a fix window
	(fixing your own sabotage is a legal cover play), and F is the kill key. A fix
	window that captured F would either eat an impostor's kill input or fire a
	kill through the window. Clicks and taps only.

	Accepted current behavior: rough visuals, no audio, no mobile sizing pass
	(the switches are large click targets, so touch works), the board rerolls on
	every open (nothing persists), and the neighbor rule is deliberately FIXED
	rather than randomized - it is meant to be learned once and then read at a
	glance.
]]

local FixSwitches = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local SWITCH_COUNT = 5
local SCRAMBLE_PRESSES = 4 -- random presses applied to the solved board
local ON_COLOR = Color3.fromRGB(100, 200, 110)
local OFF_COLOR = Color3.fromRGB(220, 70, 70)

-- Not core knobs:
local SCRAMBLE_RETRIES = 10 -- rerolls allowed if a scramble lands back on solved
local SWITCH_W, SWITCH_H = 46, 70
local SWITCH_GAP = 12
local KNOB_COLOR = Color3.fromRGB(235, 235, 235)
local FLASH_TIME = 0.25 -- seconds the green success flash stays up

function FixSwitches.Build(contentFrame, _config, onComplete)
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
	instruction.Position = UDim2.new(0, 0, 0, 12)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Restore every breaker - flipping one trips its neighbors"
	instruction.Parent = contentFrame

	-- ---- Switch row ----
	local row = track(Instance.new("Frame"))
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.new(0.5, 0, 0.5, 0)
	row.Size = UDim2.fromOffset(SWITCH_COUNT * SWITCH_W + (SWITCH_COUNT - 1) * SWITCH_GAP, SWITCH_H)
	row.BackgroundTransparency = 1
	row.Parent = contentFrame

	local rowLayout = Instance.new("UIListLayout")
	rowLayout.FillDirection = Enum.FillDirection.Horizontal
	rowLayout.Padding = UDim.new(0, SWITCH_GAP)
	rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowLayout.Parent = row -- destroyed with the row

	-- ---- Success flash overlay (green wash over the whole window) ----
	local flash = track(Instance.new("Frame"))
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.BackgroundColor3 = ON_COLOR
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.ZIndex = 10
	flash.Parent = contentFrame

	-- ============================================================
	-- State
	-- ============================================================
	local states = {} -- [i] = bool (true = on)
	local switches = {} -- [i] = { button, knob }
	local completed = false

	-- The wiring: a press flips the breaker and both of its neighbors, clamped at
	-- the ends of the row.
	local function press(i)
		for j = math.max(1, i - 1), math.min(SWITCH_COUNT, i + 1) do
			states[j] = not states[j]
		end
	end

	local function allOn()
		for i = 1, SWITCH_COUNT do
			if not states[i] then
				return false
			end
		end
		return true
	end

	-- Solvable BY CONSTRUCTION: start from the solved board and walk backwards
	-- with random presses. The press operation is its own inverse (pressing the
	-- same breaker twice restores the board), so retracing those presses always
	-- solves it - there is no unsolvable roll to guard against. The only reroll is
	-- for scrambles that happen to cancel out and land back on solved.
	local function scramble()
		for _ = 1, SCRAMBLE_RETRIES do
			for i = 1, SWITCH_COUNT do
				states[i] = true
			end
			for _ = 1, SCRAMBLE_PRESSES do
				press(math.random(SWITCH_COUNT))
			end
			if not allOn() then
				return
			end
		end
		-- Retries exhausted (vanishingly unlikely): one press guarantees the board
		-- never opens already solved.
		press(math.random(SWITCH_COUNT))
	end
	scramble()

	local function paint(i)
		local switch = switches[i]
		local on = states[i]
		switch.button.BackgroundColor3 = on and ON_COLOR or OFF_COLOR
		-- Knob rides the top of the switch when on, the bottom when off.
		switch.knob.Position = on and UDim2.new(0.5, 0, 0, 6) or UDim2.new(0.5, 0, 1, -6)
		switch.knob.AnchorPoint = on and Vector2.new(0.5, 0) or Vector2.new(0.5, 1)
	end

	local function flashSuccess()
		session += 1
		local mySession = session
		flash.BackgroundTransparency = 0.45
		task.delay(FLASH_TIME, function()
			if session ~= mySession then
				return
			end
			flash.BackgroundTransparency = 1
		end)
	end

	local function checkDone()
		if not allOn() then
			return
		end
		completed = true
		flashSuccess()
		onComplete()
	end

	for i = 1, SWITCH_COUNT do
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(SWITCH_W, SWITCH_H)
		button.LayoutOrder = i
		button.BorderSizePixel = 0
		button.Text = ""
		button.AutoButtonColor = false
		button.Parent = row -- destroyed with the row

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = button -- destroyed with the button

		local knob = Instance.new("Frame")
		knob.Size = UDim2.fromOffset(SWITCH_W - 16, 26)
		knob.BackgroundColor3 = KNOB_COLOR
		knob.BorderSizePixel = 0
		knob.ZIndex = 2
		knob.Parent = button -- destroyed with the button

		local knobCorner = Instance.new("UICorner")
		knobCorner.CornerRadius = UDim.new(0, 6)
		knobCorner.Parent = knob -- destroyed with the knob

		switches[i] = { button = button, knob = knob }
		paint(i)

		table.insert(conns, button.MouseButton1Click:Connect(function()
			if completed then
				return
			end
			press(i)
			-- Repaint the whole row: a press moves up to three breakers.
			for j = 1, SWITCH_COUNT do
				paint(j)
			end
			checkDone()
		end))
	end

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

return FixSwitches
