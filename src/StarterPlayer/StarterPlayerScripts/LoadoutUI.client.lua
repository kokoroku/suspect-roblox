--[[
	LoadoutUI.client.lua
	Pick-your-2 loadout screen, built entirely in code (no manually placed Studio
	GUI objects) so it stays version-controlled. Deliberately rough - full styling
	comes in the UI rehaul pass. No animations.

	Toggle with L, viewable at ANY time. Editing is gated by a client-side lock
	that only mirrors the server's authority (the SetLoadout AliveInMatch check):
	  - LoadoutApplied (a match started and you're in it) -> locked
	  - PlayerDied (you're a ghost now) -> unlocked, re-stage freely for next match
	  - MatchEnded (end-screen window) -> unlocked
	Default unlocked, so the pre-first-match wait and mid-match joining are
	editable. This lock/edit split becomes lobby+ghost editing once the lobby
	exists; for now the server is the real authority and this flag is just UX.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local setLoadoutEvent = Remotes.Get(Remotes.Names.SetLoadout)
local loadoutResultEvent = Remotes.Get(Remotes.Names.LoadoutResult)
local loadoutAppliedEvent = Remotes.Get(Remotes.Names.LoadoutApplied)
local playerDiedEvent = Remotes.Get(Remotes.Names.PlayerDied)
local matchEndedEvent = Remotes.Get(Remotes.Names.MatchEnded)
local getGachaCatalogFn = Remotes.Get(Remotes.FunctionNames.GetGachaCatalog)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local TOGGLE_KEY = Enum.KeyCode.L
local MAX_SLOTS = 2
local LOCKED_STATUS = "Locked while you're alive - opens if you die or at the end screen"

local locked = false
local activeLoadout = {} -- ids the server locked in for the current match
local selected = {} -- ids the player has picked to save next (max MAX_SLOTS)
local ownedList = {} -- [{ id, displayName, tier }] owned powerups, from the catalog
local ownedById = {} -- id -> { displayName, tier }

-- ============================================================
-- Build the GUI once.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LoadoutGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Size = UDim2.new(0, 320, 0, 430)
panel.Position = UDim2.new(0, 20, 0.5, -215)
panel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
panel.BackgroundTransparency = 0.1
panel.Parent = screenGui

local headerLabel = Instance.new("TextLabel")
headerLabel.Size = UDim2.new(1, -10, 0, 28)
headerLabel.Position = UDim2.new(0, 5, 0, 5)
headerLabel.BackgroundTransparency = 1
headerLabel.TextColor3 = Color3.new(1, 1, 1)
headerLabel.Font = Enum.Font.GothamBold
headerLabel.TextScaled = true
headerLabel.TextXAlignment = Enum.TextXAlignment.Left
headerLabel.Text = "Loadout - pick 2"
headerLabel.Parent = panel

local activeLabel = Instance.new("TextLabel")
activeLabel.Size = UDim2.new(1, -10, 0, 22)
activeLabel.Position = UDim2.new(0, 5, 0, 36)
activeLabel.BackgroundTransparency = 1
activeLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
activeLabel.Font = Enum.Font.Gotham
activeLabel.TextScaled = true
activeLabel.TextXAlignment = Enum.TextXAlignment.Left
activeLabel.Text = "Active this match: none"
activeLabel.Parent = panel

local rowHolder = Instance.new("ScrollingFrame")
rowHolder.Size = UDim2.new(1, -10, 1, -140)
rowHolder.Position = UDim2.new(0, 5, 0, 62)
rowHolder.BackgroundTransparency = 1
rowHolder.BorderSizePixel = 0
rowHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
rowHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
rowHolder.ScrollBarThickness = 6
rowHolder.Parent = panel

local rowLayout = Instance.new("UIListLayout")
rowLayout.Padding = UDim.new(0, 4)
rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
rowLayout.Parent = rowHolder

local saveButton = Instance.new("TextButton")
saveButton.Size = UDim2.new(0, 120, 0, 30)
saveButton.Position = UDim2.new(0, 5, 1, -72)
saveButton.BackgroundColor3 = Color3.fromRGB(70, 90, 70)
saveButton.TextColor3 = Color3.new(1, 1, 1)
saveButton.Font = Enum.Font.GothamBold
saveButton.TextScaled = true
saveButton.Text = "Save"
saveButton.Parent = panel

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -10, 0, 32)
statusLabel.Position = UDim2.new(0, 5, 1, -37)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(220, 220, 120)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextScaled = true
statusLabel.Text = ""
statusLabel.Parent = panel

-- ============================================================
-- Logic
-- ============================================================
local function setStatus(text)
	statusLabel.Text = text
end

local function isSelected(id)
	return table.find(selected, id) ~= nil
end

local function clearRows()
	for _, child in ipairs(rowHolder:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

local function renderRows()
	clearRows()
	for i, entry in ipairs(ownedList) do
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, -6, 0, 32)
		row.LayoutOrder = i
		row.AutoButtonColor = false
		row.BackgroundColor3 = isSelected(entry.id) and Color3.fromRGB(70, 110, 70) or Color3.fromRGB(50, 50, 50)
		row.TextColor3 = Color3.new(1, 1, 1)
		row.Font = Enum.Font.Gotham
		row.TextScaled = true
		row.Text = entry.displayName .. "  (Tier " .. tostring(entry.tier) .. ")"
		row.Parent = rowHolder

		row.MouseButton1Click:Connect(function()
			if locked then
				return
			end
			if isSelected(entry.id) then
				table.remove(selected, table.find(selected, entry.id))
			elseif #selected < MAX_SLOTS then
				table.insert(selected, entry.id)
			else
				setStatus("Pick only 2 - deselect one first")
				return
			end
			renderRows()
		end)
	end
end

local function refreshActiveLabel()
	if #activeLoadout == 0 then
		activeLabel.Text = "Active this match: none"
		return
	end
	local names = {}
	for _, id in ipairs(activeLoadout) do
		local info = ownedById[id]
		table.insert(names, info and info.displayName or id)
	end
	activeLabel.Text = "Active this match: " .. table.concat(names, ", ")
end

local function updateLockUI()
	if locked then
		saveButton.Visible = false
		setStatus(LOCKED_STATUS)
	else
		saveButton.Visible = true
		if statusLabel.Text == LOCKED_STATUS then
			setStatus("")
		end
	end
end

local function refreshOwned()
	local catalog = getGachaCatalogFn:InvokeServer()
	if not catalog then
		return
	end
	ownedList = {}
	ownedById = {}
	for _, entry in ipairs(catalog.powerups) do
		if entry.tier then -- owned only
			table.insert(ownedList, { id = entry.id, displayName = entry.displayName, tier = entry.tier })
			ownedById[entry.id] = { displayName = entry.displayName, tier = entry.tier }
		end
	end
	renderRows()
	refreshActiveLabel()
end

saveButton.MouseButton1Click:Connect(function()
	if locked then
		return
	end
	setLoadoutEvent:FireServer(selected)
end)

-- ============================================================
-- Remote listeners
-- ============================================================
loadoutResultEvent.OnClientEvent:Connect(function(success, reason)
	if success then
		setStatus("Saved - applies when the next match starts")
	elseif reason == "AliveInMatch" then
		setStatus("Locked while you're alive in a match")
	else
		setStatus(tostring(reason))
	end
end)

loadoutAppliedEvent.OnClientEvent:Connect(function(activeIds)
	activeLoadout = activeIds or {}
	locked = true
	refreshActiveLabel()
	updateLockUI()
end)

playerDiedEvent.OnClientEvent:Connect(function()
	locked = false
	updateLockUI()
end)

matchEndedEvent.OnClientEvent:Connect(function()
	locked = false
	updateLockUI()
end)

-- ============================================================
-- Toggle (L)
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= TOGGLE_KEY then
		return
	end
	screenGui.Enabled = not screenGui.Enabled
	if screenGui.Enabled then
		updateLockUI()
		task.spawn(refreshOwned) -- invokes the server (yields)
	end
end)
