--[[
	PowerupHUD.client.lua
	Bottom-right two-slot powerup HUD, built entirely in code (no manually placed
	Studio GUI objects) so it stays version-controlled. Deliberately rough - full
	styling comes in the UI rehaul pass.

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

local container = Instance.new("Frame")
container.Size = UDim2.new(0, 246, 0, 100)
container.Position = UDim2.new(1, -256, 1, -110)
container.BackgroundTransparency = 1
container.Parent = screenGui

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 24)
statusLabel.Position = UDim2.new(0, 0, 0, 0)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(240, 200, 120)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextScaled = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Right
statusLabel.Text = ""
statusLabel.Visible = false
statusLabel.Parent = container

-- Separate from statusLabel so a use-failure flash can't overwrite a reveal.
local seerToast = Instance.new("TextLabel")
seerToast.Size = UDim2.new(1, 0, 0, 26)
seerToast.Position = UDim2.new(0, 0, 0, -30)
seerToast.BackgroundTransparency = 1
seerToast.TextColor3 = Color3.fromRGB(140, 220, 240)
seerToast.Font = Enum.Font.GothamBold
seerToast.TextScaled = true
seerToast.TextXAlignment = Enum.TextXAlignment.Right
seerToast.Text = ""
seerToast.Visible = false
seerToast.Parent = container

-- Fire UsePowerup for a slot if it holds a powerup.
local function useSlot(index)
	local id = slotIds[index]
	if id then
		usePowerupEvent:FireServer(id)
	end
end

local function makeSlot(index, keyText)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, 120, 0, 70)
	button.Position = UDim2.new(0, (index - 1) * 126, 0, 30)
	button.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	button.BackgroundTransparency = 0.1
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = container

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -6, 0, 42)
	nameLabel.Position = UDim2.new(0, 3, 0, 3)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.Font = Enum.Font.Gotham
	nameLabel.TextScaled = true
	nameLabel.TextWrapped = true
	nameLabel.Text = "Empty"
	nameLabel.Parent = button

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Size = UDim2.new(1, -6, 0, 22)
	keyLabel.Position = UDim2.new(0, 3, 1, -24)
	keyLabel.BackgroundTransparency = 1
	keyLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	keyLabel.Font = Enum.Font.GothamBold
	keyLabel.TextScaled = true
	keyLabel.Text = keyText
	keyLabel.Parent = button

	local cooldownLabel = Instance.new("TextLabel")
	cooldownLabel.Size = UDim2.new(1, 0, 1, 0)
	cooldownLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	cooldownLabel.BackgroundTransparency = 0.5
	cooldownLabel.TextColor3 = Color3.new(1, 1, 1)
	cooldownLabel.Font = Enum.Font.GothamBold
	cooldownLabel.TextScaled = true
	cooldownLabel.Text = ""
	cooldownLabel.Visible = false
	cooldownLabel.Parent = button

	slots[index] = { nameLabel = nameLabel, cooldownLabel = cooldownLabel, token = 0 }

	button.MouseButton1Click:Connect(function()
		useSlot(index)
	end)
end

makeSlot(1, "[1]")
makeSlot(2, "[2]")

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
	seerToast.Text = "Seer: " .. tostring(name) .. " is " .. tostring(role)
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
