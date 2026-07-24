--[[
	BottomBar.client.lua
	The persistent bottom-center action bar: three buttons that open the hub
	window on a given tab. Built from UIStyle (no manually placed Studio GUI
	objects) so it stays version-controlled - functionally final, visually rough
	until the art pass re-skins UIStyle.

	Always visible, alive or dead, so a ghost has the same access as a living
	player. Hidden only while a meeting is running: it listens to the SAME
	remotes MeetingUI does - MeetingStarted opens the meeting, VoteResult ends it
	- so the bar comes back exactly when the meeting screen resolves.

	Clicking a button fires the HubOpen BindableEvent that HubUI owns and parents
	to itself; HubUI applies the open/switch/close toggle rule.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)

local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)
local voteResultEvent = Remotes.Get(Remotes.Names.VoteResult)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- HubUI creates this the moment it runs; both scripts are siblings under
-- PlayerScripts, so waiting on it is order-independent.
local hubScript = script.Parent:WaitForChild("HubUI")
local hubOpenEvent = hubScript:WaitForChild("HubOpen")

local BUTTONS = {
	{ text = "Store [G]", tab = "Store" },
	{ text = "Inventory [L]", tab = "Inventory" },
}

local BUTTON_W, BUTTON_H = 130, 38

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BottomBarGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local bar = Instance.new("Frame")
bar.AnchorPoint = Vector2.new(0.5, 1)
bar.Position = UDim2.new(0.5, 0, 1, -10)
bar.Size = UDim2.fromOffset(#BUTTONS * BUTTON_W + (#BUTTONS - 1) * UIStyle.Pad, BUTTON_H)
bar.BackgroundTransparency = 1
bar.Parent = screenGui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.VerticalAlignment = Enum.VerticalAlignment.Center
layout.Padding = UDim.new(0, UIStyle.Pad)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = bar

for i, entry in ipairs(BUTTONS) do
	local button = UIStyle.MakeButton(bar, entry.text)
	button.Size = UDim2.fromOffset(BUTTON_W, BUTTON_H)
	button.LayoutOrder = i
	button.Font = UIStyle.HeaderFont
	button.MouseButton1Click:Connect(function()
		hubOpenEvent:Fire(entry.tab)
	end)
end

-- ============================================================
-- Meeting visibility - mirrors MeetingUI's own lifecycle events.
-- ============================================================
meetingStartedEvent.OnClientEvent:Connect(function()
	screenGui.Enabled = false
end)

voteResultEvent.OnClientEvent:Connect(function()
	screenGui.Enabled = true
end)
