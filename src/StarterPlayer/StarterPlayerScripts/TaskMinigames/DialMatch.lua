--[[
	DialMatch.lua
	The "Tune the Gramophone" (DialMatch) minigame. The needle sweeps the dial on
	its own; hold F (or the on-screen button) while it passes through the arc to
	build hold time, and top up REQUIRED_HOLD seconds of clean in-arc holding to
	finish. Greedy holding is punished: holding while OUTSIDE the arc drains
	progress faster than it built, so mashing-and-holding loses ground.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events).

	Hotkey: Enum.KeyCode.F via UserInputService.InputBegan/InputEnded (gameProcessed
	guarded). Those connections live in conns, made here and dropped in cleanup, so
	F is only ever captured while this task's window is open. The on-screen
	"HOLD [F]" button drives the exact same hold state - key and button are
	interchangeable at all times (mobile parity).

	Accepted current behavior: no audio, dots-for-arc instead of a drawn wedge, no
	needle inertia or easing, no mobile sizing pass, Estate skin only.
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local ClientSettings = require(script.Parent.Parent:WaitForChild("ClientSettings"))

local DialMatch = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local SWEEP_SPEED = 160 -- deg/sec, constant, clockwise
local ARC_MIN = 45 -- arc size range (degrees)
local ARC_MAX = 85
local REQUIRED_HOLD = 1.6 -- total clean in-arc hold seconds to complete
local OUTSIDE_DRAIN_MULT = 1.25 -- holding while out-of-arc drains at this multiple of dt
local SPAWN_AHEAD_MIN = 90 -- a new arc spawns this far AHEAD of the needle (degrees)...
local SPAWN_AHEAD_MAX = 270 -- ...up to this far, guaranteeing reaction time

local DIAL_COLOR = Color3.fromRGB(45, 45, 50) -- dark dial face
local NEEDLE_COLOR = Color3.fromRGB(240, 240, 235) -- the needle
local ARC_COLOR = Color3.fromRGB(235, 200, 80) -- arc dots, not scoring
local IN_ARC_COLOR = Color3.fromRGB(100, 200, 110) -- arc dots + bar while scoring

-- Not core knobs:
local DIAL_SIZE = 170 -- dial diameter (px)
local DOT_RADIUS = 70 -- how far out (px) the arc dots sit from the dial center
local ARC_DOTS = 9 -- dots drawn along the arc
local PROGRESS_BG = Color3.fromRGB(55, 55, 60) -- dark progress track
local DRAIN_COLOR = Color3.fromRGB(220, 70, 70) -- bar tint while greedily draining

function DialMatch.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every top-level instance created inside contentFrame

	local function track(instance)
		table.insert(instances, instance)
		return instance
	end

	-- Shortest angular distance, wraparound-safe.
	local function angularDist(a, b)
		return math.abs((a - b + 180) % 360 - 180)
	end

	local function norm(a)
		return a % 360 -- Lua % is non-negative for a positive divisor, so this lands in [0,360)
	end

	-- ---- Instruction ----
	local instruction = track(Instance.new("TextLabel"))
	instruction.Size = UDim2.new(1, 0, 0, 24)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Hold F while the needle is in the green"
	instruction.Parent = contentFrame

	-- ---- Dial (a circle: square Frame + fully-rounded UICorner) ----
	local dial = track(Instance.new("Frame"))
	dial.AnchorPoint = Vector2.new(0.5, 0.5)
	dial.Position = UDim2.new(0.5, 0, 0.5, -24)
	dial.Size = UDim2.fromOffset(DIAL_SIZE, DIAL_SIZE)
	dial.BackgroundColor3 = DIAL_COLOR
	dial.BorderSizePixel = 0
	dial.Parent = contentFrame

	local dialCorner = Instance.new("UICorner")
	dialCorner.CornerRadius = UDim.new(0.5, 0) -- fully rounded
	dialCorner.Parent = dial -- destroyed with the dial

	-- ---- Needle container trick: rotating this transparent square (which covers
	-- the dial, so its center IS the dial center) pivots the needle about the dial
	-- center. GuiObject.Rotation pivots about the element's own center, so the
	-- visible needle - which reaches from the top edge to the center - must never
	-- be rotated itself. ----
	local needleContainer = Instance.new("Frame")
	needleContainer.Size = UDim2.new(1, 0, 1, 0)
	needleContainer.BackgroundTransparency = 1
	needleContainer.Parent = dial -- destroyed with the dial

	local needle = Instance.new("Frame")
	needle.Size = UDim2.new(0, 4, 0.5, 0)
	needle.Position = UDim2.new(0.5, -2, 0, 0)
	needle.BackgroundColor3 = NEEDLE_COLOR
	needle.BorderSizePixel = 0
	needle.ZIndex = 5 -- over the arc dots
	needle.Parent = needleContainer -- destroyed with the dial

	-- ---- Progress bar under the dial ----
	local progressBg = track(Instance.new("Frame"))
	progressBg.AnchorPoint = Vector2.new(0.5, 0)
	progressBg.Position = UDim2.new(0.5, 0, 0.5, -24 + DIAL_SIZE / 2 + 8)
	progressBg.Size = UDim2.fromOffset(DIAL_SIZE, 8)
	progressBg.BackgroundColor3 = PROGRESS_BG
	progressBg.BorderSizePixel = 0
	progressBg.Parent = contentFrame

	local progressFill = Instance.new("Frame")
	progressFill.Size = UDim2.new(0, 0, 1, 0)
	progressFill.BackgroundColor3 = IN_ARC_COLOR
	progressFill.BorderSizePixel = 0
	progressFill.Parent = progressBg -- destroyed with progressBg

	-- ---- On-screen fallback: HOLD [F] (mobile parity) ----
	local holdButton = track(Instance.new("TextButton"))
	holdButton.AnchorPoint = Vector2.new(0.5, 0)
	holdButton.Position = UDim2.new(0.5, 0, 0.5, -24 + DIAL_SIZE / 2 + 26)
	holdButton.Size = UDim2.fromOffset(200, 50)
	holdButton.BackgroundColor3 = Color3.fromRGB(70, 70, 90)
	holdButton.TextColor3 = Color3.new(1, 1, 1)
	holdButton.TextScaled = true
	holdButton.Font = Enum.Font.GothamBold
	holdButton.Text = "HOLD [" .. ClientSettings.GetKey("TaskAction").Name .. "]"
	holdButton.Parent = contentFrame

	local holdCorner = Instance.new("UICorner")
	holdCorner.Parent = holdButton -- destroyed with the button

	-- ============================================================
	-- Arc (exactly one at a time)
	-- ============================================================
	local dots = {} -- current arc dots (transient; destroyed on respawn / cleanup)
	local arcCenter = 0
	local arcSize = ARC_MIN

	local function setDotColors(color)
		for _, dot in ipairs(dots) do
			dot.BackgroundColor3 = color
		end
	end

	-- Rebuild the ARC_DOTS dots evenly across the current arc's angular range.
	local function buildArc()
		for _, dot in ipairs(dots) do
			dot:Destroy()
		end
		dots = {}
		local startAngle = arcCenter - arcSize / 2
		for k = 1, ARC_DOTS do
			local frac = (ARC_DOTS == 1) and 0.5 or (k - 1) / (ARC_DOTS - 1)
			local rad = math.rad(startAngle + frac * arcSize)
			-- angle 0 = up, clockwise: direction = (sin, -cos).
			local ox = DOT_RADIUS * math.sin(rad)
			local oy = -DOT_RADIUS * math.cos(rad)
			local dot = Instance.new("Frame")
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			dot.Size = UDim2.fromOffset(6, 6)
			dot.Position = UDim2.new(0.5, ox, 0.5, oy)
			dot.BackgroundColor3 = ARC_COLOR
			dot.BorderSizePixel = 0
			dot.ZIndex = 3
			dot.Parent = dial -- destroyed with the dial

			local dotCorner = Instance.new("UICorner")
			dotCorner.Parent = dot -- destroyed with the dot

			dots[k] = dot
		end
	end

	-- ============================================================
	-- State + flow
	-- ============================================================
	local angle = 0 -- needle angle, 0 = straight up
	local progress = 0
	local keyHeld = false
	local btnHeld = false
	local wasInside = false
	local completed = false

	-- Spawn the one arc a random SPAWN_AHEAD_MIN..MAX degrees ahead of the needle.
	local function spawnArc()
		arcSize = ARC_MIN + math.random() * (ARC_MAX - ARC_MIN)
		local ahead = SPAWN_AHEAD_MIN + math.random() * (SPAWN_AHEAD_MAX - SPAWN_AHEAD_MIN)
		arcCenter = norm(angle + ahead)
		wasInside = false
		buildArc()
	end
	spawnArc()

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

		-- The needle sweeps itself; the player never touches the dial.
		angle = norm(angle + SWEEP_SPEED * dt)
		needleContainer.Rotation = angle

		local inArc = angularDist(angle, arcCenter) <= arcSize / 2
		local holding = keyHeld or btnHeld

		if holding and inArc then
			progress += dt
			setDotColors(IN_ARC_COLOR)
			progressFill.BackgroundColor3 = IN_ARC_COLOR
		elseif holding and not inArc then
			-- Greedy holding: drains faster than it builds, and reads red.
			progress = math.max(0, progress - dt * OUTSIDE_DRAIN_MULT)
			setDotColors(ARC_COLOR)
			progressFill.BackgroundColor3 = DRAIN_COLOR
		else
			-- Not holding: progress frozen, dots idle.
			setDotColors(ARC_COLOR)
		end

		progressFill.Size = UDim2.new(math.clamp(progress / REQUIRED_HOLD, 0, 1), 0, 1, 0)

		if progress >= REQUIRED_HOLD then
			completed = true
			onComplete()
			return
		end

		-- Once the needle was inside and has swept past, retire the arc and spawn
		-- the next one ahead - used or not.
		if wasInside and not inArc then
			spawnArc()
		else
			wasInside = inArc
		end
	end))

	-- ============================================================
	-- Cleanup - safe at any moment (disconnects events, destroys instances).
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

return DialMatch
