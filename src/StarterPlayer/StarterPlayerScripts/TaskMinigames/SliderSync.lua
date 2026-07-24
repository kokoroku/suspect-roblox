--[[
	SliderSync.lua
	The "Trim the Gas Lamps" (SliderSync) minigame. Drag each vertical slider
	handle onto its target line; line all SLIDER_COUNT up (within tolerance) to
	finish. Sliders only move when you drag them - nothing drifts on its own.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events).

	Pointer handling matches WireSplice post-fix: InputObject.Position is ALREADY
	inset-adjusted, so it's read as-is (no GuiService / GetGuiInset). Drag-move is
	a UserInputService.InputChanged connection gated on activeDrag, never a
	connection on the dragged handle itself.

	Accepted current behavior: no audio, no animation, no mobile sizing pass,
	Estate skin only, targets reroll every open (nothing persists across opens).
]]

local UserInputService = game:GetService("UserInputService")

local SliderSync = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local SLIDER_COUNT = 3
local TOLERANCE = 0.025 -- how close (track fraction) a handle must sit to its target
local OFF_MIN = 0.2 -- a handle starts at least this far from its target, so it never opens pre-solved

local TRACK_COLOR = Color3.fromRGB(45, 45, 50) -- dark slider track
local HANDLE_COLOR = Color3.fromRGB(240, 240, 235) -- handle off-target
local ON_TARGET_COLOR = Color3.fromRGB(100, 200, 110) -- handle within tolerance
local TARGET_LINE_COLOR = Color3.fromRGB(235, 200, 80) -- the target line

-- Not core knobs:
local TRACK_W, TRACK_H = 36, 180 -- slider track size
local HANDLE_W, HANDLE_H = 44, 18 -- handle size

function SliderSync.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every top-level instance created inside contentFrame

	local function track(instance)
		table.insert(instances, instance)
		return instance
	end

	-- InputObject.Position is already inset-adjusted; read as-is.
	local function pointerFrom(input)
		return Vector2.new(input.Position.X, input.Position.Y)
	end

	-- ---- Instruction ----
	local instruction = track(Instance.new("TextLabel"))
	instruction.Size = UDim2.new(1, 0, 0, 24)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Set every slider on its line"
	instruction.Parent = contentFrame

	-- ============================================================
	-- Sliders
	-- ============================================================
	local tracks = {} -- index -> track Frame
	local handles = {} -- index -> handle TextButton
	local targetFracs = {} -- index -> target height fraction
	local fracs = {} -- index -> current handle fraction

	local function onTarget(i)
		return math.abs(fracs[i] - targetFracs[i]) <= TOLERANCE
	end

	-- Place handle i at fraction f and recolor it live.
	local function setHandle(i, f)
		fracs[i] = f
		handles[i].Position = UDim2.new(0.5, 0, f, 0)
		handles[i].BackgroundColor3 = onTarget(i) and ON_TARGET_COLOR or HANDLE_COLOR
	end

	for i = 1, SLIDER_COUNT do
		local trackFrame = track(Instance.new("Frame"))
		trackFrame.AnchorPoint = Vector2.new(0.5, 0.5)
		trackFrame.Position = UDim2.new((i - 0.5) / SLIDER_COUNT, 0, 0.5, 12)
		trackFrame.Size = UDim2.fromOffset(TRACK_W, TRACK_H)
		trackFrame.BackgroundColor3 = TRACK_COLOR
		trackFrame.BorderSizePixel = 0
		trackFrame.Parent = contentFrame
		tracks[i] = trackFrame

		local trackCorner = Instance.new("UICorner")
		trackCorner.Parent = trackFrame -- destroyed with the track

		-- Target line at a random height, rerolled every Build.
		local targetFrac = 0.1 + math.random() * 0.8 -- in [0.1, 0.9]
		targetFracs[i] = targetFrac
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.new(0.5, 0, targetFrac, 0)
		line.Size = UDim2.new(1, 0, 0, 3)
		line.BackgroundColor3 = TARGET_LINE_COLOR
		line.BorderSizePixel = 0
		line.ZIndex = 2
		line.Parent = trackFrame -- destroyed with the track

		-- Handle: start at a random fraction at least OFF_MIN from the target.
		local startFrac
		repeat
			startFrac = math.random()
		until math.abs(startFrac - targetFrac) >= OFF_MIN

		local handle = Instance.new("TextButton")
		handle.AnchorPoint = Vector2.new(0.5, 0.5)
		handle.Size = UDim2.fromOffset(HANDLE_W, HANDLE_H)
		handle.BackgroundColor3 = HANDLE_COLOR
		handle.AutoButtonColor = false
		handle.BorderSizePixel = 0
		handle.Text = ""
		handle.ZIndex = 3
		handle.Parent = trackFrame -- destroyed with the track
		handles[i] = handle

		local handleCorner = Instance.new("UICorner")
		handleCorner.Parent = handle -- destroyed with the handle

		setHandle(i, startFrac)
	end

	-- ============================================================
	-- Drag flow
	-- ============================================================
	local activeDrag = nil -- nil or a slider index
	local finished = false

	for i = 1, SLIDER_COUNT do
		table.insert(conns, handles[i].InputBegan:Connect(function(input)
			if finished then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				activeDrag = i
			end
		end))
	end

	-- Drag-move lives on UserInputService, gated on activeDrag (never on the handle).
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not activeDrag then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local trackFrame = tracks[activeDrag]
		-- Convert pointer Y to a [0,1] fraction of the track, computed at use time.
		local frac = (pointerFrom(input).Y - trackFrame.AbsolutePosition.Y) / trackFrame.AbsoluteSize.Y
		setHandle(activeDrag, math.clamp(frac, 0, 1))
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if not activeDrag then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		activeDrag = nil

		-- Check on release only, so the last slider visibly lands before closing.
		local all = true
		for i = 1, SLIDER_COUNT do
			if not onTarget(i) then
				all = false
				break
			end
		end
		if all and not finished then
			finished = true
			onComplete()
		end
	end))

	-- ============================================================
	-- Cleanup - safe at any moment, including mid-drag.
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

return SliderSync
