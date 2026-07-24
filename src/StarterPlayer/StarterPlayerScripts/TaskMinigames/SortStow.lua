--[[
	SortStow.lua
	The "Shelve the Library Books" (SortStow) minigame. Drag each colored,
	lettered book from the table into the bin that matches its category; shelve
	all of them to finish. Drop on the wrong bin (or empty space) and the book
	snaps back home, no penalty - the WireSplice miss rule.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once on success,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment (destroys instances, disconnects events).

	Pointer handling matches WireSplice post-fix: InputObject.Position is ALREADY
	inset-adjusted, so it's read as-is (no GuiService / GetGuiInset). Drag-move is
	a UserInputService.InputChanged connection gated on activeDrag, never a
	connection on the dragged book itself.

	Accepted current behavior: no audio (letters + colors carry the matching, so
	it stays colorblind-safe per the WireSplice convention), no drag ghosting /
	tween polish, no mobile sizing pass, Estate skin only.
]]

local UserInputService = game:GetService("UserInputService")

local SortStow = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local CATEGORIES = {
	{ name = "A", color = Color3.fromRGB(220, 70, 70) },
	{ name = "B", color = Color3.fromRGB(90, 140, 235) },
	{ name = "C", color = Color3.fromRGB(100, 200, 110) },
}
local ITEMS_PER_CATEGORY = 2

-- Not core knobs:
local BIN_W, BIN_H = 100, 74 -- bin size
local BOOK_W, BOOK_H = 30, 46 -- book size
local BIN_COLOR = Color3.fromRGB(45, 45, 50) -- dark bin
local DRAG_ZINDEX = 10 -- a book while dragged floats above everything

function SortStow.Build(contentFrame, _config, onComplete)
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

	local function pointInside(guiPoint, obj)
		local topLeft = obj.AbsolutePosition
		local size = obj.AbsoluteSize
		return guiPoint.X >= topLeft.X
			and guiPoint.X <= topLeft.X + size.X
			and guiPoint.Y >= topLeft.Y
			and guiPoint.Y <= topLeft.Y + size.Y
	end

	-- ---- Instruction ----
	local instruction = track(Instance.new("TextLabel"))
	instruction.Size = UDim2.new(1, 0, 0, 24)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Shelve every book in its matching slot"
	instruction.Parent = contentFrame

	-- ============================================================
	-- Bins (upper area, one per category)
	-- ============================================================
	local bins = {} -- array of { frame, categoryIndex, count }
	for c = 1, #CATEGORIES do
		local cat = CATEGORIES[c]
		local bin = track(Instance.new("Frame"))
		bin.AnchorPoint = Vector2.new(0.5, 0)
		bin.Position = UDim2.new((c - 0.5) / #CATEGORIES, 0, 0, 40)
		bin.Size = UDim2.fromOffset(BIN_W, BIN_H)
		bin.BackgroundColor3 = BIN_COLOR
		bin.BorderSizePixel = 0
		bin.Parent = contentFrame

		local binCorner = Instance.new("UICorner")
		binCorner.Parent = bin -- destroyed with the bin

		local binStroke = Instance.new("UIStroke")
		binStroke.Color = cat.color
		binStroke.Thickness = 2
		binStroke.Parent = bin -- destroyed with the bin

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Text = cat.name
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = cat.color
		label.TextScaled = true
		label.Parent = bin -- destroyed with the bin

		bins[c] = { frame = bin, categoryIndex = c, count = 0 }
	end

	-- ============================================================
	-- Books (lower "table" region). One per (category, copy), shuffled L-to-R.
	-- ============================================================
	local order = {} -- array of categoryIndex, one entry per book
	for c = 1, #CATEGORIES do
		for _ = 1, ITEMS_PER_CATEGORY do
			table.insert(order, c)
		end
	end
	-- Fisher-Yates shuffle for left-to-right placement.
	for i = #order, 2, -1 do
		local j = math.random(i)
		order[i], order[j] = order[j], order[i]
	end

	local totalBooks = #order
	local items = {} -- array of { button, categoryIndex, home, placed }
	local placedCount = 0
	local finished = false

	for k = 1, totalBooks do
		local c = order[k]
		local cat = CATEGORIES[c]

		-- Evenly spread across the lower band, with a slight random y jitter.
		local home = UDim2.new((k - 0.5) / totalBooks, 0, 0.78, math.random(-8, 8))

		local book = Instance.new("TextButton")
		book.AnchorPoint = Vector2.new(0.5, 0.5)
		book.Position = home
		book.Size = UDim2.fromOffset(BOOK_W, BOOK_H)
		book.BackgroundColor3 = cat.color
		book.AutoButtonColor = false
		book.BorderSizePixel = 0
		book.Text = cat.name
		book.Font = Enum.Font.GothamBold
		book.TextColor3 = Color3.new(1, 1, 1)
		book.TextStrokeTransparency = 0.2 -- letter reads on any color
		book.TextScaled = true
		book.ZIndex = 2
		book.Parent = contentFrame
		track(book)

		items[k] = { button = book, categoryIndex = c, home = home, placed = false }
	end

	-- ============================================================
	-- Drag flow
	-- ============================================================
	local activeDrag = nil -- nil or an items[] entry

	local function moveTo(item, input)
		-- Center follows the pointer in the content frame's local space.
		local p = pointerFrom(input) - contentFrame.AbsolutePosition
		item.button.Position = UDim2.fromOffset(p.X, p.Y)
	end

	for k = 1, totalBooks do
		local item = items[k]
		table.insert(conns, item.button.InputBegan:Connect(function(input)
			if item.placed or activeDrag ~= nil then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				activeDrag = item
				item.button.ZIndex = DRAG_ZINDEX -- float above everything while dragged
				moveTo(item, input)
			end
		end))
	end

	-- Drag-move on UserInputService, gated on activeDrag (never on the book).
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not activeDrag then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		moveTo(activeDrag, input)
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if not activeDrag then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local item = activeDrag
		activeDrag = nil
		item.button.ZIndex = 2

		local p = pointerFrom(input)
		local placedOnBin = nil
		for _, bin in ipairs(bins) do
			if pointInside(p, bin.frame) then
				if bin.categoryIndex == item.categoryIndex then
					placedOnBin = bin
				end
				break -- only one bin can be under the pointer
			end
		end

		if placedOnBin then
			-- Place neatly inside the bin, offset by how many it already holds.
			item.button.Parent = placedOnBin.frame
			item.button.AnchorPoint = Vector2.new(0, 1)
			item.button.Position = UDim2.new(0, 6 + placedOnBin.count * (BOOK_W + 6), 1, -6)
			placedOnBin.count += 1
			item.placed = true
			placedCount += 1

			if placedCount >= totalBooks and not finished then
				finished = true
				onComplete()
			end
		else
			-- Wrong bin or empty space: snap home, silently (WireSplice miss rule).
			item.button.Position = item.home
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

return SortStow
