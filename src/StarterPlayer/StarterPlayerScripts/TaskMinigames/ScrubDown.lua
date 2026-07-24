--[[
	ScrubDown.lua
	The "Polish the Silverware" (ScrubDown) minigame. Drag the pointer across the
	grimy panel to scrub it clean: each grid cell takes CELL_STAGES passes (with a
	per-cell cooldown so you can't insta-clear by parking in place). Clear
	TARGET_CLEAN of a piece to move to the next; polish PIECES pieces to finish.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events). Timed color-reverts are
	    session-token guarded so no callback touches a destroyed instance.

	Pointer handling matches WireSplice post-fix: InputObject.Position is ALREADY
	inset-adjusted, so it's read as-is (no GuiService / GetGuiInset). Drag-move is
	a UserInputService.InputChanged connection gated on a scrubbing flag; cell
	centers are precomputed as offsets and added to the scrub area's
	AbsolutePosition at use time.

	Accepted current behavior: no audio, no brush cursor visual, the "silverware"
	is an abstract shiny panel until the art pass, no mobile sizing pass, Estate
	skin only.
]]

local UserInputService = game:GetService("UserInputService")

local ScrubDown = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local PIECES = 2 -- panels to polish to finish
local GRID_COLS = 14
local GRID_ROWS = 9
local CELL_STAGES = 2 -- brush passes to fully clear a cell
local STAGE_COOLDOWN = 0.15 -- seconds a cell must wait between stage advances
local BRUSH_RADIUS = 34 -- px around the pointer that a pass affects
local TARGET_CLEAN = 0.9 -- fraction cleared to finish a piece
local GRIME_COLOR = Color3.fromRGB(105, 95, 80) -- base grime, jittered per cell
local STAGE1_TRANSPARENCY = 0.55 -- a half-scrubbed (stage 1) cell
local PANEL_COLOR = Color3.fromRGB(200, 205, 215) -- the metallic panel
local PIECE_PAUSE = 1.4 -- seconds the fully-clean panel is held before the next piece / finish
local SUCCESS_COLOR = Color3.fromRGB(100, 200, 110) -- clean-reveal panel tint + status text

-- Not core knobs:
local AREA_W, AREA_H = 350, 225 -- panel / scrub area size

function ScrubDown.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every top-level instance created inside contentFrame
	local session = 0 -- bumped by every timed revert and by cleanup

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
	instruction.Size = UDim2.new(1, -120, 0, 24)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.TextXAlignment = Enum.TextXAlignment.Left
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Scrub the grime off"
	instruction.Parent = contentFrame

	-- ---- Status (top-right) ----
	local status = track(Instance.new("TextLabel"))
	status.AnchorPoint = Vector2.new(1, 0)
	status.Size = UDim2.new(0, 150, 0, 24)
	status.Position = UDim2.new(1, -4, 0, 0)
	status.BackgroundTransparency = 1
	status.TextColor3 = Color3.new(1, 1, 1)
	status.TextScaled = true
	status.TextXAlignment = Enum.TextXAlignment.Right
	status.Font = Enum.Font.Gotham
	status.Text = ""
	status.Parent = contentFrame

	-- ---- Metallic backdrop panel ----
	local panel = track(Instance.new("Frame"))
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 12)
	panel.Size = UDim2.fromOffset(AREA_W, AREA_H)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.ZIndex = 1
	panel.Parent = contentFrame

	local panelCorner = Instance.new("UICorner")
	panelCorner.Parent = panel -- destroyed with the panel

	-- Shine: rotated GuiObjects are NOT clipped by ClipsDescendants (engine
	-- limitation), so the shine can't be rotated FRAMES - it must be a rotated
	-- GRADIENT inside an UNROTATED frame filling the panel, which cannot escape the
	-- panel bounds. Two soft diagonal bands, pure decoration.
	local shine = Instance.new("Frame")
	shine.Size = UDim2.new(1, 0, 1, 0)
	shine.BackgroundColor3 = Color3.new(1, 1, 1)
	shine.BackgroundTransparency = 0
	shine.BorderSizePixel = 0
	shine.ZIndex = 2 -- above the panel background, below the grime grid (cells are ZIndex 3)
	shine.Parent = panel -- destroyed with the panel

	local shineGradient = Instance.new("UIGradient")
	shineGradient.Rotation = 35
	shineGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.22, 1),
		NumberSequenceKeypoint.new(0.25, 0.72),
		NumberSequenceKeypoint.new(0.28, 1),
		NumberSequenceKeypoint.new(0.52, 1),
		NumberSequenceKeypoint.new(0.55, 0.8),
		NumberSequenceKeypoint.new(0.58, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	shineGradient.Parent = shine -- destroyed with the shine frame

	-- ---- Scrub area (holds the grime grid; transparent, over the panel) ----
	local area = track(Instance.new("Frame"))
	area.AnchorPoint = Vector2.new(0.5, 0.5)
	area.Position = UDim2.new(0.5, 0, 0.5, 12)
	area.Size = UDim2.fromOffset(AREA_W, AREA_H)
	area.BackgroundTransparency = 1
	area.ZIndex = 2
	area.Parent = contentFrame

	-- ============================================================
	-- Grime grid
	-- ============================================================
	local CELL_W = AREA_W / GRID_COLS
	local CELL_H = AREA_H / GRID_ROWS
	local TOTAL = GRID_COLS * GRID_ROWS

	local cells = {} -- array of { frame, stage, nextStageTime, cx, cy, dead }
	local liveCount = 0
	local currentPiece = 1
	local completed = false
	local paused = false -- true during the between-piece success pause; scrub input is ignored

	local function jitter(base)
		return math.clamp(base + math.random(-10, 10), 0, 255)
	end

	local function updateStatus()
		local percent = (TOTAL - liveCount) / TOTAL
		status.Text = string.format("Piece %d - %d%% clean", currentPiece, math.floor(percent * 100))
	end

	-- The ONE grime-grid constructor. Exactly two call sites: the end of Build
	-- (piece 1) and the piece-completion sequence advancing to the next piece.
	-- Nothing else - no input handler - may build, reset, or re-roll the grid.
	local function buildPiece(pieceIndex)
		currentPiece = pieceIndex
		for _, cell in ipairs(cells) do
			if not cell.dead then
				cell.frame:Destroy()
			end
		end
		cells = {}
		for row = 1, GRID_ROWS do
			for col = 1, GRID_COLS do
				local frame = Instance.new("Frame")
				frame.Size = UDim2.fromOffset(math.ceil(CELL_W), math.ceil(CELL_H))
				frame.Position = UDim2.fromOffset((col - 1) * CELL_W, (row - 1) * CELL_H)
				frame.BackgroundColor3 = Color3.fromRGB(jitter(105), jitter(95), jitter(80))
				frame.BorderSizePixel = 0
				frame.ZIndex = 3
				frame.Parent = area -- destroyed with the scrub area
				table.insert(cells, {
					frame = frame,
					stage = 0,
					nextStageTime = 0,
					cx = (col - 0.5) * CELL_W,
					cy = (row - 0.5) * CELL_H,
					dead = false,
				})
			end
		end
		liveCount = TOTAL
		updateStatus()
	end

	-- Piece cleared: reveal the fully clean panel, hold on it so the pause reads
	-- unambiguously as success, then build the next piece (or finish).
	local function pieceComplete()
		paused = true
		-- (1) instantly destroy every remaining grime cell so the clean panel shows.
		for _, cell in ipairs(cells) do
			if not cell.dead then
				cell.dead = true
				cell.frame:Destroy()
			end
		end
		liveCount = 0
		-- (2) tint the panel toward success and announce it in the status label.
		panel.BackgroundColor3 = PANEL_COLOR:Lerp(SUCCESS_COLOR, 0.55)
		status.TextColor3 = SUCCESS_COLOR
		status.Text = string.format("Piece %d clean!", currentPiece)
		-- (3) scrub input is ignored for the pause via the `paused` guard.
		-- (4) after the pause, restore the tint and advance or finish.
		session += 1
		local mySession = session
		task.delay(PIECE_PAUSE, function()
			if session ~= mySession then
				return
			end
			panel.BackgroundColor3 = PANEL_COLOR
			if currentPiece >= PIECES then
				completed = true
				onComplete()
			else
				status.TextColor3 = Color3.new(1, 1, 1)
				buildPiece(currentPiece + 1)
				paused = false
			end
		end)
	end

	-- ============================================================
	-- Scrubbing
	-- ============================================================
	local scrubbing = false
	local radiusSq = BRUSH_RADIUS * BRUSH_RADIUS

	local function brushPass(input)
		if completed or paused then
			return
		end
		local p = pointerFrom(input) - area.AbsolutePosition
		local now = os.clock()
		for _, cell in ipairs(cells) do
			if not cell.dead and now >= cell.nextStageTime then
				local dx = p.X - cell.cx
				local dy = p.Y - cell.cy
				if dx * dx + dy * dy <= radiusSq then
					cell.stage += 1
					cell.nextStageTime = now + STAGE_COOLDOWN
					if cell.stage >= CELL_STAGES then
						cell.dead = true
						cell.frame:Destroy()
						liveCount -= 1
					else
						cell.frame.BackgroundTransparency = STAGE1_TRANSPARENCY
					end
				end
			end
		end
		updateStatus()
		if not completed and (TOTAL - liveCount) / TOTAL >= TARGET_CLEAN then
			pieceComplete()
		end
	end

	-- Start scrubbing on press; one pass immediately so taps scrub too.
	table.insert(conns, area.InputBegan:Connect(function(input)
		if completed or paused then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			scrubbing = true
			brushPass(input)
		end
	end))

	-- Drag-move on UserInputService, gated on the scrubbing flag.
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not scrubbing then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		brushPass(input)
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			scrubbing = false
		end
	end))

	-- Piece 1: the only initial grid build (the other call site is piece completion).
	buildPiece(1)

	-- ============================================================
	-- Cleanup - safe at any moment, including mid-scrub. Bump session FIRST so any
	-- in-flight flash revert aborts before it can touch a destroyed instance.
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

return ScrubDown
