--[[
	FixValve.lua
	The "Vent the Boiler" fix minigame - the repair for the Boiler sabotage. Hold
	the valve wheel down to bleed the pressure bar up to full; let go and it falls
	back faster than it rose, so the fix wants one committed hold.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events).

	CLICK-ONLY - NO HOTKEY. Fix minigames must NEVER bind F (or any world action
	key) the way task minigames do: an impostor is allowed to open a fix window
	(fixing your own sabotage is a legal cover play), and F is the kill key. A fix
	window that captured F would either eat an impostor's kill input or fire a
	kill through the window. The hold is driven by the button's own
	InputBegan/InputEnded (mouse or touch) - the Placeholder hold pattern, never
	UserInputService.

	Accepted current behavior: rough visuals, no audio, no mobile sizing pass (the
	valve is one big hold target, so touch works), nothing persists across opens.
]]

local RunService = game:GetService("RunService")

local FixValve = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local VENT_TIME = 2.5 -- seconds of unbroken holding to fill the bar
local DRAIN_MULT = 2 -- release drains at this multiple of the fill speed

-- Not core knobs:
local VALVE_SIZE = 130
local VALVE_COLOR = Color3.fromRGB(90, 80, 70)
local VALVE_HELD_COLOR = Color3.fromRGB(130, 115, 95)
local BAR_BG_COLOR = Color3.fromRGB(45, 45, 50)
local BAR_FILL_COLOR = Color3.fromRGB(220, 120, 60)
local BAR_DONE_COLOR = Color3.fromRGB(100, 200, 110)

function FixValve.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every top-level instance created inside contentFrame

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
	instruction.Text = "Hold to vent the pressure"
	instruction.Parent = contentFrame

	-- ---- Pressure bar ----
	local barBg = track(Instance.new("Frame"))
	barBg.AnchorPoint = Vector2.new(0.5, 0)
	barBg.Position = UDim2.new(0.5, 0, 0, 48)
	barBg.Size = UDim2.new(1, -60, 0, 22)
	barBg.BackgroundColor3 = BAR_BG_COLOR
	barBg.BorderSizePixel = 0
	barBg.Parent = contentFrame

	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = BAR_FILL_COLOR
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg -- destroyed with barBg

	-- ---- Valve wheel ----
	local valve = track(Instance.new("TextButton"))
	valve.AnchorPoint = Vector2.new(0.5, 0)
	valve.Position = UDim2.new(0.5, 0, 0, 88)
	valve.Size = UDim2.fromOffset(VALVE_SIZE, VALVE_SIZE)
	valve.BackgroundColor3 = VALVE_COLOR
	valve.TextColor3 = Color3.new(1, 1, 1)
	valve.Font = Enum.Font.GothamBold
	valve.TextSize = 20
	valve.Text = "VALVE"
	valve.AutoButtonColor = false
	valve.Parent = contentFrame

	-- Radius >= half the size makes the button read as a wheel, not a card.
	local valveCorner = Instance.new("UICorner")
	valveCorner.CornerRadius = UDim.new(1, 0)
	valveCorner.Parent = valve -- destroyed with the valve

	-- ============================================================
	-- Hold logic
	-- ============================================================
	local holding = false
	local progress = 0
	local completed = false

	local function updateBar()
		barFill.Size = UDim2.new(progress, 0, 1, 0)
	end

	local function setHolding(state)
		if completed then
			return
		end
		holding = state
		valve.BackgroundColor3 = state and VALVE_HELD_COLOR or VALVE_COLOR
	end

	-- Mouse or touch, both through the button itself - no keyboard binding.
	table.insert(conns, valve.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			setHolding(true)
		end
	end))
	table.insert(conns, valve.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			setHolding(false)
		end
	end))
	-- Dragging off the wheel counts as letting go.
	table.insert(conns, valve.MouseLeave:Connect(function()
		setHolding(false)
	end))

	table.insert(conns, RunService.Heartbeat:Connect(function(dt)
		if completed then
			return
		end

		if holding then
			progress = math.min(1, progress + dt / VENT_TIME)
		else
			-- Falls back faster than it rises: releasing costs you real ground.
			progress = math.max(0, progress - (dt / VENT_TIME) * DRAIN_MULT)
		end
		updateBar()

		if progress >= 1 then
			completed = true
			holding = false
			barFill.BackgroundColor3 = BAR_DONE_COLOR
			valve.BackgroundColor3 = VALVE_COLOR
			onComplete()
		end
	end))

	-- ============================================================
	-- Cleanup - safe at any moment.
	-- ============================================================
	return function()
		for _, connection in ipairs(conns) do
			connection:Disconnect()
		end
		for _, instance in ipairs(instances) do
			instance:Destroy()
		end
	end
end

return FixValve
