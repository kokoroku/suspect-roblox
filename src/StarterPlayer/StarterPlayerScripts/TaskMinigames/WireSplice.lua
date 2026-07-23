--[[
	WireSplice.lua
	The "Rewire the Chandelier" (WireSplice) minigame. Drag each colored plug on
	the left to its matching socket on the right; connect all of them to finish.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once when every wire is connected,
	  - returns a cleanup that fully undoes everything (safe to call mid-drag;
	    the runner calls it on walk-away, meetings, death and respawn).
]]

local UserInputService = game:GetService("UserInputService")

local WireSplice = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local WIRE_COUNT = 4
local WIRES = {
	{ name = "Red", color = Color3.fromRGB(220, 70, 70), label = "1" },
	{ name = "Yellow", color = Color3.fromRGB(235, 200, 80), label = "2" },
	{ name = "Blue", color = Color3.fromRGB(90, 140, 235), label = "3" },
	{ name = "Green", color = Color3.fromRGB(100, 200, 110), label = "4" },
}
local NODE_SIZE = 40
local WIRE_THICKNESS = 6

-- How much darker an unconnected socket is than its plug (not a core knob).
local SOCKET_DIM = 0.5

function WireSplice.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every instance created inside contentFrame

	local function track(instance)
		table.insert(instances, instance)
		return instance
	end

	local function darken(color, factor)
		return Color3.new(color.R * factor, color.G * factor, color.B * factor)
	end

	-- ---- Instruction ----
	local instruction = track(Instance.new("TextLabel"))
	instruction.Size = UDim2.new(1, 0, 0, 24)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Connect each wire to its matching socket"
	instruction.Parent = contentFrame

	-- ---- Wire layer (wires always render UNDER the nodes) ----
	local wireLayer = track(Instance.new("Frame"))
	wireLayer.Size = UDim2.new(1, 0, 1, 0)
	wireLayer.BackgroundTransparency = 1
	wireLayer.ZIndex = 1
	wireLayer.Parent = contentFrame

	-- ---- Node factory (plugs and sockets share construction) ----
	local function makeNode(bgColor, labelText)
		local node = track(Instance.new("TextButton"))
		node.Size = UDim2.fromOffset(NODE_SIZE, NODE_SIZE)
		node.BackgroundColor3 = bgColor
		node.BorderSizePixel = 0
		node.ZIndex = 2
		node.Text = labelText
		node.Font = Enum.Font.GothamBold
		node.TextScaled = true
		node.TextColor3 = Color3.new(1, 1, 1)
		node.TextStrokeTransparency = 0.2 -- number reads on any color
		node.Parent = contentFrame

		local corner = Instance.new("UICorner")
		corner.Parent = node -- destroyed with the node

		return node
	end

	-- Evenly spaced down the band below the 24px instruction label. Y center of
	-- row = 24 + (H - 24) * frac  ==  scale frac, offset 24*(1-frac).
	local function rowY(row)
		local frac = (row - 0.5) / WIRE_COUNT
		return frac, 24 * (1 - frac)
	end

	-- ---- Plugs (left, in wire order) ----
	local plugs = {} -- wireIndex -> button
	for i = 1, WIRE_COUNT do
		local wire = WIRES[i]
		local plug = makeNode(wire.color, wire.label)
		plug.AnchorPoint = Vector2.new(0, 0.5)
		local frac, offset = rowY(i)
		plug.Position = UDim2.new(0, 24, frac, offset)
		plugs[i] = plug
	end

	-- ---- Sockets (right, order is a fresh shuffle of wire indices) ----
	local socketOrder = {}
	for i = 1, WIRE_COUNT do
		socketOrder[i] = i
	end
	for i = WIRE_COUNT, 2, -1 do
		local j = math.random(i)
		socketOrder[i], socketOrder[j] = socketOrder[j], socketOrder[i]
	end

	local socketList = {} -- array of { wireIndex, button }
	for row = 1, WIRE_COUNT do
		local wireIndex = socketOrder[row]
		local wire = WIRES[wireIndex]
		local socket = makeNode(darken(wire.color, SOCKET_DIM), wire.label)
		socket.AnchorPoint = Vector2.new(1, 0.5)
		local frac, offset = rowY(row)
		socket.Position = UDim2.new(1, -24, frac, offset)
		table.insert(socketList, { wireIndex = wireIndex, button = socket })
	end

	-- ============================================================
	-- Geometry helpers
	-- ============================================================
	-- Node center in wireLayer-local pixels, computed AT USE TIME so layout
	-- settling can never skew a cached value.
	local function nodeCenter(node)
		return node.AbsolutePosition + node.AbsoluteSize / 2 - wireLayer.AbsolutePosition
	end

	local function positionWire(frame, fromPx, toPx)
		local delta = toPx - fromPx
		local dist = delta.Magnitude
		local mid = (fromPx + toPx) / 2
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromOffset(mid.X, mid.Y)
		frame.Size = UDim2.fromOffset(dist, WIRE_THICKNESS)
		frame.Rotation = math.deg(math.atan2(delta.Y, delta.X))
	end

	-- InputObject.Position is ALREADY in the same inset-adjusted space as
	-- GuiObject.AbsolutePosition, so it's read as-is (no GetGuiInset subtraction).
	-- Used directly for socket hit-tests; subtract wireLayer.AbsolutePosition to
	-- get a wireLayer-local endpoint for the live wire.
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

	-- ============================================================
	-- State + input flow
	-- ============================================================
	local connected = {} -- wireIndex -> true once locked
	local activeDrag = nil -- nil or { wireIndex, wireFrame }
	local finished = false

	-- Plug: begin a drag.
	for i = 1, WIRE_COUNT do
		local plug = plugs[i]
		table.insert(conns, plug.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end
			if finished or connected[i] or activeDrag ~= nil then
				return
			end

			local wireFrame = Instance.new("Frame")
			wireFrame.BackgroundColor3 = WIRES[i].color
			wireFrame.BorderSizePixel = 0
			wireFrame.ZIndex = 1
			wireFrame.Parent = wireLayer -- under the nodes; destroyed with wireLayer

			activeDrag = { wireIndex = i, wireFrame = wireFrame }

			positionWire(wireFrame, nodeCenter(plug), pointerFrom(input) - wireLayer.AbsolutePosition)
		end))
	end

	-- Drag: follow the pointer.
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if not activeDrag then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		positionWire(activeDrag.wireFrame, nodeCenter(plugs[activeDrag.wireIndex]), pointerFrom(input) - wireLayer.AbsolutePosition)
	end))

	-- Release: lock into the matching socket, or silently miss.
	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		if not activeDrag then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local p = pointerFrom(input)
		local locked = false
		for _, entry in ipairs(socketList) do
			if pointInside(p, entry.button) then
				if entry.wireIndex == activeDrag.wireIndex then
					local plug = plugs[activeDrag.wireIndex]
					positionWire(activeDrag.wireFrame, nodeCenter(plug), nodeCenter(entry.button))
					connected[activeDrag.wireIndex] = true
					entry.button.BackgroundColor3 = WIRES[activeDrag.wireIndex].color
					plug.AutoButtonColor = false
					locked = true
				end
				break -- only one socket can be under the pointer
			end
		end

		if not locked then
			-- Wrong socket or empty space: silent miss, no penalty.
			activeDrag.wireFrame:Destroy()
		end
		activeDrag = nil

		if locked then
			local all = true
			for i = 1, WIRE_COUNT do
				if not connected[i] then
					all = false
					break
				end
			end
			if all and not finished then
				finished = true
				onComplete()
			end
		end
	end))

	-- ============================================================
	-- Cleanup - safe at any moment, including mid-drag.
	-- ============================================================
	return function()
		for _, connection in ipairs(conns) do
			connection:Disconnect()
		end
		if activeDrag and activeDrag.wireFrame then
			activeDrag.wireFrame:Destroy()
			activeDrag = nil
		end
		for _, instance in ipairs(instances) do
			instance:Destroy()
		end
	end
end

return WireSplice
