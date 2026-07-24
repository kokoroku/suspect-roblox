--[[
	TaskListUI.client.lua
	Compact task checklist HUD, built entirely in code (no manually placed
	Studio GUI objects) so it stays version-controlled. Styled from UIStyle -
	deliberately plain until the art pass, which re-skins UIStyle, not this file.

	UI lifecycle:
	  - Driven entirely by the TasksUpdated remote: the server sends this
	    player their OWN { [taskId] = done } table at match start and again
	    after every completion. The list is rebuilt from scratch each time.
	  - Impostors are never sent the event, so they never see this GUI -
	    that IS the visibility mechanism, there is no client-side role check.
	  - Stays visible during meetings and after death - fine for now.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local TaskDefs = require(ReplicatedStorage.Modules.TaskDefs)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local tasksUpdatedEvent = Remotes.Get(Remotes.Names.TasksUpdated)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local PANEL_WIDTH = 185
local PANEL_HEIGHT = 230
local MIN_SIZE = Vector2.new(150, 110)
local MAX_SIZE = Vector2.new(320, 500)

-- ============================================================
-- Build the GUI once. It stays disabled until this player is actually
-- assigned at least one task. Draggable by its header row and resizable by the
-- edges/corners; the rows live in a scroller, so a longer list scrolls rather
-- than overflowing and a bigger window is simply a bigger viewport.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TaskListGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local panel = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
	UDim2.new(0, 12, 0, 12),
	Vector2.new(0, 0)
)

local panelPadding = Instance.new("UIPadding")
panelPadding.PaddingTop = UDim.new(0, UIStyle.Pad)
panelPadding.PaddingBottom = UDim.new(0, UIStyle.Pad)
panelPadding.PaddingLeft = UDim.new(0, UIStyle.Pad)
panelPadding.PaddingRight = UDim.new(0, UIStyle.Pad)
panelPadding.Parent = panel

-- ---- Header row: "Tasks" left, the done/total count right in Accent ----
local headerRow = Instance.new("Frame")
headerRow.Size = UDim2.new(1, 0, 0, 18)
headerRow.Position = UDim2.new(0, 0, 0, 0)
headerRow.BackgroundTransparency = 1
headerRow.Parent = panel

local title = UIStyle.MakeLabel(headerRow, "Tasks")
title.Size = UDim2.new(1, -50, 1, 0)
title.FontFace = UIStyle.HeaderFontFace
title.TextSize = 15

local countLabel = UIStyle.MakeLabel(headerRow, "0/0")
countLabel.AnchorPoint = Vector2.new(1, 0)
countLabel.Position = UDim2.new(1, 0, 0, 0)
countLabel.Size = UDim2.new(0, 50, 1, 0)
countLabel.FontFace = UIStyle.HeaderFontFace
countLabel.TextSize = 14
countLabel.TextColor3 = UIStyle.Colors.Accent
countLabel.TextXAlignment = Enum.TextXAlignment.Right

-- ---- Progress bar, directly under the header ----
local progressTrack = Instance.new("Frame")
progressTrack.Size = UDim2.new(1, 0, 0, 4)
progressTrack.Position = UDim2.new(0, 0, 0, 22)
progressTrack.BackgroundColor3 = UIStyle.Colors.Row
progressTrack.BorderSizePixel = 0
progressTrack.Parent = panel

local progressFill = Instance.new("Frame")
progressFill.Size = UDim2.new(0, 0, 1, 0)
progressFill.BackgroundColor3 = UIStyle.Colors.Positive
progressFill.BorderSizePixel = 0
progressFill.Parent = progressTrack -- destroyed with the track

-- Rows live in a scroller filling everything under the progress bar, so the
-- panel's height is a viewport rather than a limit.
local taskHolder = Instance.new("ScrollingFrame")
taskHolder.Position = UDim2.new(0, 0, 0, 32)
taskHolder.Size = UDim2.new(1, 0, 1, -32)
taskHolder.BackgroundTransparency = 1
taskHolder.BorderSizePixel = 0
taskHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
taskHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
taskHolder.ScrollBarThickness = 4
taskHolder.Parent = panel

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 1)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = taskHolder

-- Drag by the header row, resize by any edge or corner. Session-only memory:
-- reapplied whenever the list comes back on screen, reset on rejoin by design.
local savedPosition = panel.Position
local savedSize = panel.Size

UIStyle.MakeDraggable(panel, headerRow)
UIStyle.MakeResizable(panel, MIN_SIZE, MAX_SIZE)

panel:GetPropertyChangedSignal("Position"):Connect(function()
	savedPosition = panel.Position
end)
panel:GetPropertyChangedSignal("Size"):Connect(function()
	savedSize = panel.Size
end)

local function clearTaskLabels()
	for _, child in ipairs(taskHolder:GetChildren()) do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
end

-- Task text comes from the shared def now (the Estate-skin displayName), no
-- longer derived from the raw part-name task ID.
local function displayName(taskType)
	return TaskDefs.Get(taskType).displayName
end

-- Tiny all-caps group divider ("LONG" / "SHORT").
local function makeHeaderLabel(text, layoutOrder)
	local label = UIStyle.MakeLabel(taskHolder, text, true)
	label.Size = UDim2.new(1, 0, 0, 14)
	label.LayoutOrder = layoutOrder
	label.FontFace = UIStyle.HeaderFontFace
	label.TextSize = 10
end

-- Pending tasks read in their length's color; done ones drop to dim with a
-- leading checkmark.
local function makeTaskLabel(taskType, done, layoutOrder, pendingColor)
	local label = UIStyle.MakeLabel(taskHolder, "", done)
	label.Size = UDim2.new(1, 0, 0, 18)
	label.LayoutOrder = layoutOrder
	label.TextSize = 13
	label.TextTruncate = Enum.TextTruncate.AtEnd
	if done then
		label.Text = "\u{2713} " .. displayName(taskType)
	else
		label.TextColor3 = pendingColor
		label.Text = displayName(taskType)
	end
end

-- ============================================================
-- Task list updates
-- Payload is now { [taskId] = { done, taskType } }. We split into Long/Short
-- groups, each alphabetical by display name, with a small header per group.
-- ============================================================
tasksUpdatedEvent.OnClientEvent:Connect(function(tasks)
	clearTaskLabels()

	local longEntries, shortEntries = {}, {}
	local doneCount, totalCount = 0, 0
	for _, entry in pairs(tasks) do
		totalCount += 1
		if entry.done then
			doneCount += 1
		end
		if TaskDefs.Get(entry.taskType).length == "Long" then
			table.insert(longEntries, entry)
		else
			table.insert(shortEntries, entry)
		end
	end

	local function byDisplayName(a, b)
		return displayName(a.taskType) < displayName(b.taskType)
	end
	table.sort(longEntries, byDisplayName)
	table.sort(shortEntries, byDisplayName)

	-- LayoutOrder ticks up across both groups so the order stays stable.
	local order = 0
	-- Empty groups are omitted entirely - no stray header over nothing.
	local function addGroup(headerText, entries, pendingColor)
		if #entries == 0 then
			return
		end
		makeHeaderLabel(headerText, order)
		order += 1
		for _, entry in ipairs(entries) do
			makeTaskLabel(entry.taskType, entry.done, order, pendingColor)
			order += 1
		end
	end

	addGroup("LONG", longEntries, UIStyle.Colors.TaskLong)
	addGroup("SHORT", shortEntries, UIStyle.Colors.TaskShort)

	countLabel.Text = string.format("%d/%d", doneCount, totalCount)
	progressFill.Size = UDim2.new(totalCount > 0 and (doneCount / totalCount) or 0, 0, 1, 0)

	if totalCount > 0 and not screenGui.Enabled then
		-- Coming back on screen: restore wherever the player dragged/sized it.
		panel.Position = savedPosition
		panel.Size = savedSize
	end
	screenGui.Enabled = totalCount > 0
end)
