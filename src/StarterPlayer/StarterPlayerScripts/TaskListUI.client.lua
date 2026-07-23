--[[
	TaskListUI.client.lua
	Minimal task checklist HUD, built entirely in code (no manually placed
	Studio GUI objects) so it stays version-controlled. Not styled/polished
	yet - that's a later art pass, this just needs to work.

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
local tasksUpdatedEvent = Remotes.Get(Remotes.Names.TasksUpdated)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local DONE_COLOR = Color3.fromRGB(120, 220, 120)

-- ============================================================
-- Build the GUI once. It stays disabled until this player is actually
-- assigned at least one task.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TaskListGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.new(0, 10, 0, 10)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.BackgroundTransparency = 0.2
frame.Parent = screenGui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.new(1, 1, 1)
title.TextScaled = true
title.Font = Enum.Font.GothamBold
title.Text = "Tasks (0/0)"
title.Parent = frame

local taskHolder = Instance.new("Frame")
taskHolder.Size = UDim2.new(1, 0, 0, 0)
taskHolder.Position = UDim2.new(0, 0, 0, 30)
taskHolder.AutomaticSize = Enum.AutomaticSize.Y
taskHolder.BackgroundTransparency = 1
taskHolder.Parent = frame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 2)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = taskHolder

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

local function makeHeaderLabel(text, layoutOrder)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 20)
	label.LayoutOrder = layoutOrder
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(200, 200, 200)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.Parent = taskHolder
end

local function makeTaskLabel(taskType, done, layoutOrder)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 24)
	label.LayoutOrder = layoutOrder
	label.BackgroundTransparency = 1
	label.TextColor3 = done and DONE_COLOR or Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.Gotham
	label.Text = (done and "\u{2713} " or "\u{2022} ") .. displayName(taskType)
	label.Parent = taskHolder
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
	local function addGroup(headerText, entries)
		if #entries == 0 then
			return
		end
		makeHeaderLabel(headerText, order)
		order += 1
		for _, entry in ipairs(entries) do
			makeTaskLabel(entry.taskType, entry.done, order)
			order += 1
		end
	end

	addGroup("Long tasks", longEntries)
	addGroup("Short tasks", shortEntries)

	title.Text = string.format("Tasks (%d/%d)", doneCount, totalCount)
	screenGui.Enabled = totalCount > 0
end)
