--[[
	SpotCheck.lua
	The "Find the Master's Keys" (SpotCheck) minigame. A cluttered drawer of
	procedural junk; click the KEY_COUNT actual keys hidden among DECOY_COUNT
	decoys to finish. Keys always render on top of the pile, so a round is always
	winnable - they're hard to spot, never occluded. Clicking a decoy just flashes
	it red, no penalty.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events). Timed color-reverts are
	    session-token guarded so no callback touches a destroyed instance.

	Click-native: no drag, no hotkey. Everything rerolls per Build.

	Accepted current behavior: no audio, procedural clutter (no assets), keys
	always on top of the pile by design, no mobile sizing pass, Estate skin only.
]]

local SpotCheck = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local KEY_COUNT = 4
local DECOY_COUNT = 32 -- reduced so the scene breathes
local KEY_MIN_SEPARATION = 60 -- px between key centers

local KEY_COLOR = Color3.fromRGB(170, 140, 64) -- brass key (dimmed - the silhouette, not brightness, gives it away)
local SCENE_COLOR = Color3.fromRGB(58, 46, 36) -- dark drawer
local FOUND_COLOR = Color3.fromRGB(100, 200, 110) -- a found key
local MISS_COLOR = Color3.fromRGB(220, 70, 70) -- a clicked decoy

-- Not core knobs:
local SCENE_W, SCENE_H = 380, 235 -- scene size
local PLACE_COLS, PLACE_ROWS = 8, 5 -- structured-scatter placement grid (one object per cell, shuffled)
local JITTER_FRAC = 0.4 -- object offset from its cell center, up to this fraction of the cell size
local SEPARATION_ATTEMPTS = 30 -- tries to re-draw a key's cell before accepting
local FLASH_TIME = 0.25 -- seconds a decoy stays red

function SpotCheck.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every top-level instance created inside contentFrame
	local session = 0 -- bumped by every timed revert and by cleanup

	local function track(instance)
		table.insert(instances, instance)
		return instance
	end

	-- ---- Instruction ----
	local instruction = track(Instance.new("TextLabel"))
	instruction.Size = UDim2.new(1, -120, 0, 24)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.TextXAlignment = Enum.TextXAlignment.Left
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Find the " .. KEY_COUNT .. " keys"
	instruction.Parent = contentFrame

	-- ---- Counter (top-right) ----
	local counter = track(Instance.new("TextLabel"))
	counter.AnchorPoint = Vector2.new(1, 0)
	counter.Size = UDim2.new(0, 110, 0, 24)
	counter.Position = UDim2.new(1, -4, 0, 0)
	counter.BackgroundTransparency = 1
	counter.TextColor3 = Color3.new(1, 1, 1)
	counter.TextScaled = true
	counter.TextXAlignment = Enum.TextXAlignment.Right
	counter.Font = Enum.Font.Gotham
	counter.Text = ""
	counter.Parent = contentFrame

	local foundCount = 0
	local completed = false

	local function updateCounter()
		counter.Text = string.format("Found %d/%d", foundCount, KEY_COUNT)
	end
	updateCounter()

	-- ---- Scene ----
	local scene = track(Instance.new("Frame"))
	scene.AnchorPoint = Vector2.new(0.5, 0.5)
	scene.Position = UDim2.new(0.5, 0, 0.5, 14)
	scene.Size = UDim2.fromOffset(SCENE_W, SCENE_H)
	scene.BackgroundColor3 = SCENE_COLOR
	scene.BorderSizePixel = 0
	scene.ClipsDescendants = true
	scene.Parent = contentFrame

	-- A colored part frame inside a container, tracked for later tinting.
	local function makePart(container, color, sizeX, sizeY, offX, offY, zindex, rounded)
		local part = Instance.new("Frame")
		part.AnchorPoint = Vector2.new(0.5, 0.5)
		part.Size = UDim2.fromOffset(sizeX, sizeY)
		part.Position = UDim2.new(0.5, offX, 0.5, offY)
		part.BackgroundColor3 = color
		part.BorderSizePixel = 0
		part.ZIndex = zindex
		part.Parent = container
		if rounded then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = part
		end
		return part
	end

	-- ---- Key: RING head (the hole sells "key") + stem + two teeth hanging down,
	-- random rotation, on top. Identification is by SILHOUETTE, not brightness. ----
	local function makeKey(cx, cy)
		local container = Instance.new("TextButton")
		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.Size = UDim2.fromOffset(36, 16)
		container.Position = UDim2.fromOffset(cx, cy)
		container.BackgroundTransparency = 1
		container.Text = ""
		container.AutoButtonColor = false
		container.Rotation = math.random(-80, 80)
		container.ZIndex = 5
		container.Parent = scene

		-- Head is a ring: a transparent circle whose UIStroke draws the outline.
		local head = Instance.new("Frame")
		head.AnchorPoint = Vector2.new(0.5, 0.5)
		head.Size = UDim2.fromOffset(13, 13)
		head.Position = UDim2.new(0.5, -11, 0.5, 0)
		head.BackgroundTransparency = 1
		head.BorderSizePixel = 0
		head.ZIndex = 5
		head.Parent = container

		local headCorner = Instance.new("UICorner")
		headCorner.CornerRadius = UDim.new(0.5, 0)
		headCorner.Parent = head -- destroyed with the head

		local headStroke = Instance.new("UIStroke")
		headStroke.Thickness = 3
		headStroke.Color = KEY_COLOR
		headStroke.Parent = head -- destroyed with the head

		local parts = {
			head, -- included so the shared recolor covers it (its outline is the stroke, below)
			makePart(container, KEY_COLOR, 18, 4, 4, 0, 5, false), -- stem
			makePart(container, KEY_COLOR, 4, 6, 10, 4, 5, false), -- tooth (hangs down)
			makePart(container, KEY_COLOR, 4, 6, 14, 6, 5, false), -- tooth (slightly lower)
		}
		return container, parts, headStroke
	end

	-- ---- Decoy makers (all return the container + its colored part frames) ----
	local MID_GRAY = Color3.fromRGB(120, 120, 120)
	local DARK_BRASS = Color3.fromRGB(140, 115, 60)
	local DULL_SILVER = Color3.fromRGB(170, 170, 175)

	local function decoyBolt(container, sz, z)
		return { makePart(container, MID_GRAY, sz, sz, 0, 0, z, true) } -- washer/bolt circle
	end
	local function decoyHook(container, sz, z)
		-- Two frames in an L; dark brass, deliberately key-adjacent in color.
		return {
			makePart(container, DARK_BRASS, math.max(3, sz // 3), sz, -sz // 4, 0, z, false),
			makePart(container, DARK_BRASS, sz, math.max(3, sz // 3), 0, sz // 3, z, false),
		}
	end
	local function decoyScrap(container, sz, z)
		local muted = Color3.fromRGB(math.random(90, 130), math.random(80, 115), math.random(70, 100))
		return { makePart(container, muted, sz, math.max(4, math.floor(sz * (0.5 + math.random() * 0.6))), 0, 0, z, false) }
	end
	local function decoyCoin(container, sz, z)
		return { makePart(container, DULL_SILVER, sz, sz, 0, 0, z, true) }
	end
	local DECOY_MAKERS = { decoyBolt, decoyHook, decoyScrap, decoyCoin }

	local function flashMiss(parts, origColors)
		session += 1
		local mySession = session
		for _, part in ipairs(parts) do
			part.BackgroundColor3 = MISS_COLOR
		end
		task.delay(FLASH_TIME, function()
			if session ~= mySession then
				return
			end
			for i, part in ipairs(parts) do
				part.BackgroundColor3 = origColors[i]
			end
		end)
	end

	-- ============================================================
	-- Structured scatter: one object per placement-grid cell (shuffled), each at
	-- its cell center plus jitter. No two objects share a cell, so nothing stacks.
	-- ============================================================
	local PCELL_W = SCENE_W / PLACE_COLS
	local PCELL_H = SCENE_H / PLACE_ROWS

	local pool = {} -- shuffled placement cells; each object consumes one
	for row = 1, PLACE_ROWS do
		for col = 1, PLACE_COLS do
			table.insert(pool, { col = col, row = row })
		end
	end
	for i = #pool, 2, -1 do
		local j = math.random(i)
		pool[i], pool[j] = pool[j], pool[i]
	end

	-- A random point in a cell: its center plus up to JITTER_FRAC of the cell size.
	local function cellPos(cell)
		local cx = (cell.col - 0.5) * PCELL_W + (math.random() * 2 - 1) * JITTER_FRAC * PCELL_W
		local cy = (cell.row - 0.5) * PCELL_H + (math.random() * 2 - 1) * JITTER_FRAC * PCELL_H
		return cx, cy
	end

	-- ---- Build the clutter (decoys first, under the keys) ----
	for _ = 1, DECOY_COUNT do
		local sz = math.random(10, 26)
		local z = math.random(2, 4)
		local dcx, dcy = cellPos(table.remove(pool))
		local container = Instance.new("TextButton")
		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.Size = UDim2.fromOffset(sz, sz)
		container.Position = UDim2.fromOffset(dcx, dcy)
		container.BackgroundTransparency = 1
		container.Text = ""
		container.AutoButtonColor = false
		container.Rotation = math.random(0, 360)
		container.ZIndex = z
		container.Parent = scene

		local maker = DECOY_MAKERS[math.random(#DECOY_MAKERS)]
		local parts = maker(container, sz, z)
		local origColors = {}
		for i, part in ipairs(parts) do
			origColors[i] = part.BackgroundColor3
		end

		table.insert(conns, container.Activated:Connect(function()
			if completed then
				return
			end
			flashMiss(parts, origColors)
		end))
	end

	-- ---- Place the keys AFTER decoys: each gets its own distinct cell, with the
	-- KEY_MIN_SEPARATION pairwise check on top (re-draw the cell if violated). ----
	local keyCenters = {}
	for _ = 1, KEY_COUNT do
		local chosen, kx, ky
		for attempt = 1, SEPARATION_ATTEMPTS do
			local j = math.random(#pool)
			local tx, ty = cellPos(pool[j])
			local ok = true
			for _, c in ipairs(keyCenters) do
				local dx, dy = tx - c.X, ty - c.Y
				if dx * dx + dy * dy < KEY_MIN_SEPARATION * KEY_MIN_SEPARATION then
					ok = false
					break
				end
			end
			if ok or attempt == SEPARATION_ATTEMPTS then
				chosen, kx, ky = j, tx, ty
				break -- accepted (or out of attempts: accept anyway)
			end
		end
		-- Consume the chosen cell (swap-remove) so no other object reuses it.
		pool[chosen] = pool[#pool]
		pool[#pool] = nil
		table.insert(keyCenters, Vector2.new(kx, ky))

		local container, parts, stroke = makeKey(kx, ky)
		local found = false
		table.insert(conns, container.Activated:Connect(function()
			if completed or found then
				return
			end
			found = true
			for _, part in ipairs(parts) do
				part.BackgroundColor3 = FOUND_COLOR
			end
			stroke.Color = FOUND_COLOR -- the ring's outline lives in its stroke, not BackgroundColor3
			foundCount += 1
			updateCounter()
			if foundCount >= KEY_COUNT then
				completed = true
				onComplete()
			end
		end))
	end

	-- ============================================================
	-- Cleanup - safe at any moment. Bump session FIRST so any in-flight decoy
	-- flash revert aborts before it can touch a destroyed instance.
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

return SpotCheck
