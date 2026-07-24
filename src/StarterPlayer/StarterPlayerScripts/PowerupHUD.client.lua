--[[
	PowerupHUD.client.lua
	Bottom-right two-slot powerup HUD, built entirely in code (no manually placed
	Studio GUI objects) so it stays version-controlled. Styled from UIStyle -
	deliberately plain until the art pass, which re-skins UIStyle, not this file.

	Lifecycle:
	  - LoadoutApplied (fired at match start) fills the two slots with the active
	    loadout's powerups. An empty slot shows "Empty" and does nothing.
	  - Keys [1]/[2] or clicking a slot fire UsePowerup with that slot's id.
	  - PowerupUseResult drives feedback: on success a per-slot cooldown countdown
	    overlays the slot; on failure a short status line flashes the reason.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local usePowerupEvent = Remotes.Get(Remotes.Names.UsePowerup)
local powerupUseResultEvent = Remotes.Get(Remotes.Names.PowerupUseResult)
local loadoutAppliedEvent = Remotes.Get(Remotes.Names.LoadoutApplied)
local seerResultEvent = Remotes.Get(Remotes.Names.SeerResult)
local getGachaCatalogFn = Remotes.Get(Remotes.FunctionNames.GetGachaCatalog)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Friendly text per failure reason (some arrive with the effects work later -
-- mapping them now costs nothing). Falls back to the raw reason string.
local REASON_TEXT = {
	OnCooldown = "On cooldown",
	MeetingActive = "Can't use during meetings",
	MatchNotInProgress = "Match hasn't started",
	NotEquipped = "Not equipped",
	NotImplementedYet = "Coming soon",
	MinAliveNotMet = "Not enough players alive",
	NoTargetNearby = "No one close enough",
	LightsAreOn = "Only works in the dark",
	NoUsesLeft = "No uses left this match",
}

local slotIds = { nil, nil } -- powerupId equipped in each slot (or nil)
local slots = {} -- [i] = { nameLabel, cooldownLabel, token }
local displayNameById = {} -- resolved lazily from the gacha catalog

-- ============================================================
-- Build the GUI once.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PowerupHUDGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = true
screenGui.Parent = playerGui

local SLOT_SIZE = 64
local SLOT_GAP = 8
local EDGE = 10 -- distance from the bottom-right corner

-- Slot strip, hugging the bottom-right corner.
local container = Instance.new("Frame")
container.AnchorPoint = Vector2.new(1, 1)
container.Size = UDim2.fromOffset(SLOT_SIZE * 2 + SLOT_GAP, SLOT_SIZE)
container.Position = UDim2.new(1, -EDGE, 1, -EDGE)
container.BackgroundTransparency = 1
container.Parent = screenGui

-- Failure-reason line, directly above the slots.
local statusLabel = UIStyle.MakeLabel(screenGui, "", true)
statusLabel.AnchorPoint = Vector2.new(1, 1)
statusLabel.Size = UDim2.fromOffset(240, 20)
statusLabel.Position = UDim2.new(1, -EDGE, 1, -(EDGE + SLOT_SIZE + 4))
statusLabel.TextColor3 = UIStyle.Colors.Accent
statusLabel.TextXAlignment = Enum.TextXAlignment.Right
statusLabel.Visible = false

-- Separate from statusLabel so a use-failure flash can't overwrite a reveal.
local seerToast = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(240, 26),
	UDim2.new(1, -EDGE, 1, -(EDGE + SLOT_SIZE + 28)),
	Vector2.new(1, 1)
)
seerToast.Visible = false

local seerStroke = seerToast:FindFirstChildOfClass("UIStroke")
if seerStroke then
	seerStroke.Color = UIStyle.Colors.Accent
end

local seerLabel = UIStyle.MakeLabel(seerToast, "")
seerLabel.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, 0)
seerLabel.Position = UDim2.new(0, UIStyle.Pad, 0, 0)
seerLabel.Font = UIStyle.HeaderFont
seerLabel.TextSize = 12
seerLabel.TextXAlignment = Enum.TextXAlignment.Right

-- Fire UsePowerup for a slot if it holds a powerup.
local function useSlot(index)
	local id = slotIds[index]
	if id then
		usePowerupEvent:FireServer(id)
	end
end

local function makeSlot(index, keyText)
	local slot = UIStyle.MakePanel(
		container,
		UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
		UDim2.fromOffset((index - 1) * (SLOT_SIZE + SLOT_GAP), 0),
		Vector2.new(0, 0)
	)

	local nameLabel = UIStyle.MakeLabel(slot, "Empty")
	nameLabel.Size = UDim2.new(1, -8, 1, -20)
	nameLabel.Position = UDim2.new(0, 4, 0, 16)
	nameLabel.TextSize = 11
	nameLabel.TextWrapped = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center

	-- Keybind badge: a dark key cap in the slot's top-left corner. Padded so the
	-- scaled digit never touches an edge.
	local keyBadge = UIStyle.MakeLabel(slot, keyText)
	keyBadge.Size = UDim2.fromOffset(20, 20)
	keyBadge.Position = UDim2.fromOffset(4, 4)
	keyBadge.BackgroundTransparency = 0
	keyBadge.BackgroundColor3 = UIStyle.Colors.Bg
	keyBadge.FontFace = UIStyle.HeaderFontFace
	keyBadge.TextScaled = true
	keyBadge.TextColor3 = UIStyle.Colors.Accent
	keyBadge.TextXAlignment = Enum.TextXAlignment.Center
	keyBadge.TextYAlignment = Enum.TextYAlignment.Center

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 4)
	badgeCorner.Parent = keyBadge -- destroyed with the badge

	local badgeStroke = Instance.new("UIStroke")
	badgeStroke.Thickness = 1
	badgeStroke.Color = UIStyle.Colors.Accent
	badgeStroke.Parent = keyBadge -- destroyed with the badge

	local badgePadding = Instance.new("UIPadding")
	badgePadding.PaddingTop = UDim.new(0, 3)
	badgePadding.PaddingBottom = UDim.new(0, 3)
	badgePadding.PaddingLeft = UDim.new(0, 3)
	badgePadding.PaddingRight = UDim.new(0, 3)
	badgePadding.Parent = keyBadge -- destroyed with the badge

	-- Click target over the whole slot (a Frame can't take MouseButton1Click).
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, 0, 1, 0)
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.Text = ""
	button.ZIndex = 5
	button.Parent = slot

	-- Doubles as the cooldown darkener AND the countdown number. Above the click
	-- target so it reads on top; labels don't sink input, so clicks still land.
	local cooldownLabel = UIStyle.MakeLabel(slot, "")
	cooldownLabel.Size = UDim2.new(1, 0, 1, 0)
	cooldownLabel.BackgroundTransparency = 0.35
	cooldownLabel.BackgroundColor3 = UIStyle.Colors.Bg
	cooldownLabel.Font = UIStyle.HeaderFont
	cooldownLabel.TextSize = 22
	cooldownLabel.TextXAlignment = Enum.TextXAlignment.Center
	cooldownLabel.Visible = false
	cooldownLabel.ZIndex = 6

	local cooldownCorner = Instance.new("UICorner")
	cooldownCorner.CornerRadius = UDim.new(0, UIStyle.Corner)
	cooldownCorner.Parent = cooldownLabel -- destroyed with the overlay

	slots[index] = { nameLabel = nameLabel, cooldownLabel = cooldownLabel, token = 0 }

	button.MouseButton1Click:Connect(function()
		useSlot(index)
	end)
end

makeSlot(1, "1")
makeSlot(2, "2")

-- ============================================================
-- Feedback helpers
-- ============================================================
local statusToken = 0
local function flashStatus(text)
	statusLabel.Text = text
	statusLabel.Visible = true
	statusToken = statusToken + 1
	local myToken = statusToken
	task.delay(2, function()
		if myToken == statusToken then
			statusLabel.Visible = false
		end
	end)
end

-- Per-slot generation token so overlapping results can't fight over the overlay.
local function startCooldown(index, seconds)
	local slot = slots[index]
	slot.token = slot.token + 1
	local myToken = slot.token
	task.spawn(function()
		local remaining = math.ceil(seconds)
		while remaining > 0 do
			if slot.token ~= myToken then
				return -- superseded by a newer result / new loadout
			end
			slot.cooldownLabel.Text = tostring(remaining)
			slot.cooldownLabel.Visible = true
			task.wait(1)
			remaining = remaining - 1
		end
		if slot.token == myToken then
			slot.cooldownLabel.Visible = false
		end
	end)
end

local function slotOf(powerupId)
	if slotIds[1] == powerupId then
		return 1
	elseif slotIds[2] == powerupId then
		return 2
	end
	return nil
end

local function populateSlots(ids)
	for i = 1, 2 do
		local id = ids[i]
		slotIds[i] = id
		slots[i].nameLabel.Text = id and (displayNameById[id] or id) or "Empty"
		-- Cancel any running cooldown display for this slot.
		slots[i].token = slots[i].token + 1
		slots[i].cooldownLabel.Visible = false
	end
end

-- ============================================================
-- Remote listeners
-- ============================================================
loadoutAppliedEvent.OnClientEvent:Connect(function(activeIds)
	local ids = activeIds or {}
	-- Resolve display names from the catalog (yields), then fill the slots.
	task.spawn(function()
		local catalog = getGachaCatalogFn:InvokeServer()
		if catalog then
			for _, entry in ipairs(catalog.powerups) do
				displayNameById[entry.id] = entry.displayName
			end
		end
		populateSlots(ids)
	end)
end)

powerupUseResultEvent.OnClientEvent:Connect(function(powerupId, success, reason, cooldown)
	local index = slotOf(powerupId)
	if success then
		if index and cooldown then
			startCooldown(index, cooldown)
		end
	else
		flashStatus(REASON_TEXT[reason] or tostring(reason))
	end
end)

-- Seer reveal - shown longer than a status flash and on its own label.
local seerToastToken = 0
seerResultEvent.OnClientEvent:Connect(function(name, role)
	seerLabel.Text = "Seer: " .. tostring(name) .. " is " .. tostring(role)
	seerToast.Visible = true
	seerToastToken = seerToastToken + 1
	local myToken = seerToastToken
	task.delay(6, function()
		if myToken == seerToastToken then
			seerToast.Visible = false
		end
	end)
end)

-- ============================================================
-- Keybinds [1] / [2]
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.One then
		useSlot(1)
	elseif input.KeyCode == Enum.KeyCode.Two then
		useSlot(2)
	end
end)
