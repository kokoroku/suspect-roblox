--[[
	FlowRoute.lua
	The "Mend the Boiler Pipes" (FlowRoute) minigame. Rotate the pipe tiles so
	water flows from the source (left edge) all the way to the drain (right edge).
	The board is generated backwards from a real solution, so every round is
	solvable by construction; the scramble is nudged so it never opens pre-solved.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events). Timed color-reverts are
	    session-token guarded so no callback touches a destroyed instance.

	Click-native: each tile rotates 90 degrees per click; no drag, no hotkey.

	Accepted current behavior: no audio, instant 90-degree snaps (no rotation
	animation), straights and elbows only (no T-pieces / crossovers), distractor
	tiles can incidentally form wet side-branches (reads as leaky plumbing), no
	mobile sizing pass, Estate skin only.
]]

local FlowRoute = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local GRID = 4
local TILE = 52 -- tile size (px)
local GAP = 4 -- gap between tiles (px)
local ELBOW_BIAS = 0.6 -- chance a distractor tile is an elbow (else straight)
local PIPE_COLOR = Color3.fromRGB(150, 150, 155) -- dry pipe
local WET_COLOR = Color3.fromRGB(90, 160, 235) -- water-carrying pipe
local TILE_BG = Color3.fromRGB(45, 45, 50) -- dark tile background
local DONE_COLOR = Color3.fromRGB(100, 200, 110) -- completion flash

-- Not core knobs:
local HUB = 14 -- center hub / arm width (px)
local FLASH_TIME = 0.35 -- seconds the finished route flashes green

-- ============================================================
-- Piece model. Directions: 0=N, 1=E, 2=S, 3=W.
-- A tile is { shape, rot }; a shape's base open dirs are each rotated (d+rot)%4.
-- ============================================================
local BASE = {
	straight = { 0, 2 }, -- opposite pair
	elbow = { 0, 1 }, -- adjacent pair
}

-- Row/col deltas per direction.
local DELTA = {
	[0] = { -1, 0 }, -- N
	[1] = { 0, 1 }, -- E
	[2] = { 1, 0 }, -- S
	[3] = { 0, -1 }, -- W
}

local function openSet(shape, rot)
	local s = {}
	for _, d in ipairs(BASE[shape]) do
		s[(d + rot) % 4] = true
	end
	return s
end

local function openDirs(tile)
	return openSet(tile.shape, tile.rot)
end

-- The (shape, rot) whose open dirs are exactly {a, b}: opposite pair -> straight,
-- adjacent pair -> elbow. Found by testing the 4 rotations of each shape.
local function pieceFor(a, b)
	for _, shape in ipairs({ "straight", "elbow" }) do
		for rot = 0, 3 do
			local od = openSet(shape, rot)
			if od[a] and od[b] then
				return shape, rot
			end
		end
	end
end

function FlowRoute.Build(contentFrame, _config, onComplete)
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
	instruction.Text = "Rotate the pipes to route the water"
	instruction.Parent = contentFrame

	-- ============================================================
	-- Board state
	-- ============================================================
	local tiles = {} -- tiles[row][col] = { shape, rot, isPath, row, col, button, hub, arms }
	local sourceRow, drainRow
	local finished = false

	-- Flood fill from the source; returns the wet set and whether the drain is fed.
	local function computeFlow()
		local wet = {}
		for r = 1, GRID do
			wet[r] = {}
		end
		local queue = {}
		if openDirs(tiles[sourceRow][1])[3] then -- cell (sourceRow,1) opens West to the source
			wet[sourceRow][1] = true
			table.insert(queue, { sourceRow, 1 })
		end
		local qi = 1
		while qi <= #queue do
			local cell = queue[qi]
			qi += 1
			local r, c = cell[1], cell[2]
			local od = openDirs(tiles[r][c])
			for d = 0, 3 do
				if od[d] then
					local nr, nc = r + DELTA[d][1], c + DELTA[d][2]
					if nr >= 1 and nr <= GRID and nc >= 1 and nc <= GRID and not wet[nr][nc] then
						if openDirs(tiles[nr][nc])[(d + 2) % 4] then -- neighbor faces back
							wet[nr][nc] = true
							table.insert(queue, { nr, nc })
						end
					end
				end
			end
		end
		local complete = (wet[drainRow][GRID] and openDirs(tiles[drainRow][GRID])[1]) or false
		return wet, complete
	end

	-- Generate the board backwards from a serpentine solution, then scramble.
	local function generate()
		sourceRow = math.random(1, GRID)
		drainRow = math.random(1, GRID)
		tiles = {}
		for r = 1, GRID do
			tiles[r] = {}
		end

		-- Carve the path column by column, recording each cell's entry/exit dirs.
		local pathList = {}
		local entryRow = sourceRow
		local prevEntry = 3 -- the first cell is entered from the West (the source)
		for col = 1, GRID do
			local targetRow = (col == GRID) and drainRow or math.random(1, GRID)
			local step = 0
			if targetRow > entryRow then
				step = 1
			elseif targetRow < entryRow then
				step = -1
			end
			local r = entryRow
			while true do
				local exitDir
				if r == targetRow then
					exitDir = 1 -- East: into the next column (or out to the drain on the last)
				else
					exitDir = (step == 1) and 2 or 0 -- keep heading toward targetRow
				end
				local entryDir
				if r == entryRow then
					entryDir = prevEntry
				else
					entryDir = (step == 1) and 0 or 2 -- came from the cell we just stepped off
				end
				local shape, rot = pieceFor(entryDir, exitDir)
				tiles[r][col] = { shape = shape, rot = rot, isPath = true, row = r, col = col }
				table.insert(pathList, { r = r, c = col })
				if r == targetRow then
					break
				end
				r += step
			end
			prevEntry = 3 -- stepping East, the next column's first cell is entered from the West
			entryRow = targetRow
		end

		-- Distractors fill every non-path cell.
		for r = 1, GRID do
			for c = 1, GRID do
				if not tiles[r][c] then
					local shape = (math.random() < ELBOW_BIAS) and "elbow" or "straight"
					tiles[r][c] = { shape = shape, rot = math.random(0, 3), isPath = false, row = r, col = c }
				end
			end
		end

		-- Scramble EVERY tile's rotation.
		for r = 1, GRID do
			for c = 1, GRID do
				tiles[r][c].rot = math.random(0, 3)
			end
		end

		-- Never open pre-solved: while the drain is reached, bump a random PATH
		-- tile (bounded; the first bump breaks the connection).
		local iter = 0
		while iter < 10 do
			local _, complete = computeFlow()
			if not complete then
				break
			end
			local pc = pathList[math.random(#pathList)]
			tiles[pc.r][pc.c].rot = (tiles[pc.r][pc.c].rot + 1) % 4
			iter += 1
		end
	end
	generate()

	-- ============================================================
	-- Rendering
	-- ============================================================
	local BOARD = GRID * TILE + (GRID - 1) * GAP

	local board = track(Instance.new("Frame"))
	board.AnchorPoint = Vector2.new(0.5, 0.5)
	board.Position = UDim2.new(0.5, 0, 0.5, 12)
	board.Size = UDim2.fromOffset(BOARD, BOARD)
	board.BackgroundTransparency = 1
	board.Parent = contentFrame

	-- Rebuild a tile's arms from its current open dirs (an arm reaches from the
	-- center hub out to one edge). Destroyed and rebuilt on every rotation.
	local function buildArms(tile)
		for _, arm in ipairs(tile.arms) do
			arm:Destroy()
		end
		tile.arms = {}
		local od = openDirs(tile)
		for d = 0, 3 do
			if od[d] then
				local arm = Instance.new("Frame")
				arm.BorderSizePixel = 0
				arm.Position = UDim2.new(0.5, 0, 0.5, 0)
				arm.BackgroundColor3 = PIPE_COLOR
				arm.ZIndex = 2
				if d == 0 then -- N
					arm.AnchorPoint = Vector2.new(0.5, 1)
					arm.Size = UDim2.fromOffset(HUB, TILE / 2)
				elseif d == 2 then -- S
					arm.AnchorPoint = Vector2.new(0.5, 0)
					arm.Size = UDim2.fromOffset(HUB, TILE / 2)
				elseif d == 1 then -- E
					arm.AnchorPoint = Vector2.new(0, 0.5)
					arm.Size = UDim2.fromOffset(TILE / 2, HUB)
				else -- W
					arm.AnchorPoint = Vector2.new(1, 0.5)
					arm.Size = UDim2.fromOffset(TILE / 2, HUB)
				end
				arm.Parent = tile.button
				table.insert(tile.arms, arm)
			end
		end
	end

	for r = 1, GRID do
		for c = 1, GRID do
			local tile = tiles[r][c]

			local button = Instance.new("TextButton")
			button.Size = UDim2.fromOffset(TILE, TILE)
			button.Position = UDim2.fromOffset((c - 1) * (TILE + GAP), (r - 1) * (TILE + GAP))
			button.BackgroundColor3 = TILE_BG
			button.AutoButtonColor = false
			button.BorderSizePixel = 0
			button.Text = ""
			button.Parent = board

			local corner = Instance.new("UICorner")
			corner.Parent = button -- destroyed with the button

			local hub = Instance.new("Frame")
			hub.AnchorPoint = Vector2.new(0.5, 0.5)
			hub.Position = UDim2.new(0.5, 0, 0.5, 0)
			hub.Size = UDim2.fromOffset(HUB, HUB)
			hub.BackgroundColor3 = PIPE_COLOR
			hub.BorderSizePixel = 0
			hub.ZIndex = 3
			hub.Parent = button

			tile.button = button
			tile.hub = hub
			tile.arms = {}
			buildArms(tile)
		end
	end

	-- Source marker (left edge, always wet) and drain marker (right edge).
	local sourceMarker = Instance.new("Frame")
	sourceMarker.AnchorPoint = Vector2.new(1, 0.5)
	sourceMarker.Position = UDim2.fromOffset(-6, (sourceRow - 1) * (TILE + GAP) + TILE / 2)
	sourceMarker.Size = UDim2.fromOffset(10, HUB)
	sourceMarker.BackgroundColor3 = WET_COLOR
	sourceMarker.BorderSizePixel = 0
	sourceMarker.Parent = board -- destroyed with the board

	local drainMarker = Instance.new("Frame")
	drainMarker.AnchorPoint = Vector2.new(0, 0.5)
	drainMarker.Position = UDim2.fromOffset(BOARD + 6, (drainRow - 1) * (TILE + GAP) + TILE / 2)
	drainMarker.Size = UDim2.fromOffset(10, HUB)
	drainMarker.BackgroundColor3 = PIPE_COLOR
	drainMarker.BorderSizePixel = 0
	drainMarker.Parent = board -- destroyed with the board

	-- Recolor every tile from a wet set (wet = WET_COLOR, dry = PIPE_COLOR).
	local function recolor(wet)
		for r = 1, GRID do
			for c = 1, GRID do
				local tile = tiles[r][c]
				local color = wet[r][c] and WET_COLOR or PIPE_COLOR
				tile.hub.BackgroundColor3 = color
				for _, arm in ipairs(tile.arms) do
					arm.BackgroundColor3 = color
				end
			end
		end
	end

	local function runFlow()
		local wet, complete = computeFlow()
		recolor(wet)
		return wet, complete
	end

	local function finish(wet)
		finished = true
		drainMarker.BackgroundColor3 = DONE_COLOR
		-- Flash the whole connected route green, then settle back to wet blue.
		session += 1
		local mySession = session
		for r = 1, GRID do
			for c = 1, GRID do
				if wet[r][c] then
					local tile = tiles[r][c]
					tile.hub.BackgroundColor3 = DONE_COLOR
					for _, arm in ipairs(tile.arms) do
						arm.BackgroundColor3 = DONE_COLOR
					end
				end
			end
		end
		task.delay(FLASH_TIME, function()
			if session ~= mySession then
				return
			end
			for r = 1, GRID do
				for c = 1, GRID do
					if wet[r][c] then
						local tile = tiles[r][c]
						tile.hub.BackgroundColor3 = WET_COLOR
						for _, arm in ipairs(tile.arms) do
							arm.BackgroundColor3 = WET_COLOR
						end
					end
				end
			end
		end)
		onComplete()
	end

	-- Wire up rotation clicks.
	for r = 1, GRID do
		for c = 1, GRID do
			local tile = tiles[r][c]
			table.insert(conns, tile.button.Activated:Connect(function()
				if finished then
					return
				end
				tile.rot = (tile.rot + 1) % 4
				buildArms(tile)
				local wet, complete = runFlow()
				if complete then
					finish(wet)
				end
			end))
		end
	end

	-- Initial paint.
	runFlow()

	-- ============================================================
	-- Cleanup - safe at any moment. Bump session FIRST so any in-flight flash
	-- revert aborts before it can touch a destroyed instance.
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

return FlowRoute
