--[[
	SabotagePanel.client.lua
	The impostor's sabotage panel: press C to toggle a small list of sabotages,
	click one to fire it. Built entirely in code (matches MeetingUI's house style)
	- deliberately rough, restyled in the UI rehaul pass.

	IMPOSTOR-ONLY: the panel is gated on RoleAssigned, which the server sends to
	each player individually. A new match can flip the local role either way, so
	every RoleAssigned re-decides whether this panel exists at all - a crewmate
	never sees it, and never keeps it from a previous round.

	The server is the ONLY authority on whether a sabotage may fire (role, alive,
	match state, meeting, cooldown, already-active). Everything shown here is
	display: the row states are a best-effort local mirror, and a rejection from
	the server always wins and is flashed on the status line.

	COOLDOWN DISPLAY: SabotageStatus carries no cooldown field, so the countdown
	is mirrored from the server's tuning - the 30s post-fix cooldown starts when a
	broadcast reports a sabotage went from active to resolved, and the 20s opening
	delay starts at RoleAssigned (match start). Purely a label; nothing here gates
	the remote, and no remote is ever polled.

	Accepted current behavior: rough visuals, no sabotage sounds, no mobile
	sizing pass (the rows are click targets, so touch works).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local roleAssignedEvent = Remotes.Get(Remotes.Names.RoleAssigned)
local sabotageStatusEvent = Remotes.Get(Remotes.Names.SabotageStatus)
local triggerSabotageEvent = Remotes.Get(Remotes.Names.TriggerSabotage)
local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)
local playerDiedEvent = Remotes.Get(Remotes.Names.PlayerDied)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local TOGGLE_KEY = Enum.KeyCode.C
local IMPOSTOR_ROLE = "Impostor"

-- Mirrors of SabotageService's tuning, for the countdown LABEL only.
local SABOTAGE_COOLDOWN = 30
local MATCH_START_DELAY = 20

-- Row order is the display order.
local SABOTAGES = {
	{ type = "Lights", name = "Snuff the Gas Lamps" },
	{ type = "Boiler", name = "Overload the Boiler" },
}

-- Friendly text per rejection reason; falls back to the raw reason string.
local REASON_TEXT = {
	Cooldown = "Not ready yet",
	AlreadyActive = "Something is already broken",
}

-- ============================================================
-- Build the GUI once. Enabled only while the panel is open.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SabotagePanelGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local setOpen -- forward declared; the header's X needs it before it exists

local panel = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(220, 170),
	UDim2.new(0, 16, 0.5, 0),
	Vector2.new(0, 0.5)
)
-- Sinks clicks so a click on the panel can never reach a world ProximityPrompt.
panel.Active = true

local headerStrip = UIStyle.MakeHeader(panel, "Sabotage", function()
	setOpen(false)
end)

-- Drag by the header. No resize - the panel is two rows and a status line.
-- Session-only memory, same as the hub: reset on rejoin by design.
local savedPosition = panel.Position

UIStyle.MakeDraggable(panel, headerStrip)

panel:GetPropertyChangedSignal("Position"):Connect(function()
	savedPosition = panel.Position
end)

local statusLabel = UIStyle.MakeLabel(panel, "", true)
statusLabel.AnchorPoint = Vector2.new(0, 1)
statusLabel.Position = UDim2.new(0, UIStyle.Pad, 1, -6)
statusLabel.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 18)
statusLabel.TextSize = 12
statusLabel.TextColor3 = UIStyle.Colors.Accent

-- ---- One row per sabotage ----
local rows = {} -- [i] = { type, button, stateLabel }

for i, entry in ipairs(SABOTAGES) do
	local button = UIStyle.MakeButton(panel, "  " .. entry.name)
	button.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 42)
	button.Position = UDim2.new(0, UIStyle.Pad, 0, 44 + (i - 1) * 50)
	button.FontFace = UIStyle.HeaderFontFace
	button.TextXAlignment = Enum.TextXAlignment.Left

	local stateLabel = UIStyle.MakeLabel(button, "Ready", true)
	stateLabel.AnchorPoint = Vector2.new(1, 1)
	stateLabel.Position = UDim2.new(1, -UIStyle.Pad, 1, -4)
	stateLabel.Size = UDim2.new(0, 110, 0, 14)
	stateLabel.TextSize = 11
	stateLabel.TextXAlignment = Enum.TextXAlignment.Right

	rows[i] = { type = entry.type, button = button, stateLabel = stateLabel }
end

-- ============================================================
-- State
-- ============================================================
local isImpostor = false
local activeType = nil -- the sabotage currently running, per the last broadcast
local cooldownUntil = 0 -- os.clock() value the mirrored cooldown label counts to
local statusToken = 0

setOpen = function(open)
	-- Crew never get the panel, whatever the key says.
	local show = open and isImpostor
	if show then
		panel.Position = savedPosition -- reopen where the player left it
	end
	screenGui.Enabled = show
end

local function refreshRows()
	local remaining = cooldownUntil - os.clock()
	for _, row in ipairs(rows) do
		if activeType == row.type then
			row.stateLabel.Text = "Active"
			row.stateLabel.TextColor3 = UIStyle.Colors.Negative
		elseif remaining > 0 then
			row.stateLabel.Text = string.format("Cooldown %ds", math.ceil(remaining))
			row.stateLabel.TextColor3 = UIStyle.Colors.TextDim
		else
			row.stateLabel.Text = "Ready"
			row.stateLabel.TextColor3 = UIStyle.Colors.Positive
		end
	end
end

local function flashStatus(text)
	statusLabel.Text = text
	statusToken += 1
	local myToken = statusToken
	task.delay(2.5, function()
		if statusToken == myToken then
			statusLabel.Text = ""
		end
	end)
end

for _, row in ipairs(rows) do
	row.button.MouseButton1Click:Connect(function()
		-- Fire and close. The row state is only a hint - the server re-checks
		-- everything, and a rejection comes back on SabotageStatus.
		triggerSabotageEvent:FireServer(row.type)
		setOpen(false)
	end)
end

-- ============================================================
-- Remote-driven state
-- ============================================================
sabotageStatusEvent.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" then
		return
	end

	if data.rejected then
		-- The panel was closed by the click that got rejected, so put it back up:
		-- the reason is the whole point of the message.
		setOpen(true)
		flashStatus(REASON_TEXT[data.reason] or tostring(data.reason))
		refreshRows()
		return
	end

	local wasActive = activeType ~= nil
	activeType = data.active and data.type or nil
	if wasActive and activeType == nil then
		-- A sabotage just ended, so the server armed its post-fix cooldown.
		cooldownUntil = os.clock() + SABOTAGE_COOLDOWN
	end
	refreshRows()
end)

roleAssignedEvent.OnClientEvent:Connect(function(role)
	isImpostor = (role == IMPOSTOR_ROLE)
	-- Fresh match: no sabotage running, and the server armed the opening delay.
	activeType = nil
	cooldownUntil = os.clock() + MATCH_START_DELAY
	statusLabel.Text = ""
	setOpen(false) -- always starts closed; the key opens it
	refreshRows()
end)

-- ============================================================
-- Force-hides. Both reopen only by keypress.
-- ============================================================
meetingStartedEvent.OnClientEvent:Connect(function()
	setOpen(false)
end)

playerDiedEvent.OnClientEvent:Connect(function()
	setOpen(false)
end)

-- ============================================================
-- Toggle key
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode ~= TOGGLE_KEY then
		return
	end
	if not isImpostor then
		return
	end

	if screenGui.Enabled then
		setOpen(false)
	else
		refreshRows()
		setOpen(true)
	end
end)

-- Ticks the mirrored cooldown label while the panel is up. UI only - it never
-- asks the server anything.
task.spawn(function()
	while true do
		task.wait(1)
		if screenGui.Enabled then
			refreshRows()
		end
	end
end)
