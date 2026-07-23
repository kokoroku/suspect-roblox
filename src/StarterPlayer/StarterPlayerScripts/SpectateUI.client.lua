--[[
	SpectateUI.client.lua
	Dead-player spectate experience, built entirely in code (no manually placed
	Studio GUI objects) so it stays version-controlled. Deliberately rough - full
	styling comes in the UI rehaul pass. No animations.

	Lifecycle:
	  - Server fires PlayerDied when this player dies. After DEATH_VIEW_DELAY
	    seconds (long enough to watch your own body drop) spectate engages: the
	    camera follows a living player and a bottom bar lets you cycle targets
	    (< / > buttons or Q/E), open a gacha panel, or hit a placeholder
	    Return to Lobby button.
	  - The server keeps the target list fresh via SpectateTargetsUpdated (only
	    ever sent to dead players).
	  - Spectate ends when the local character respawns (CharacterAdded), which
	    happens on every match restart - no MatchEnded handling needed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local spectateTargetsEvent = Remotes.Get(Remotes.Names.SpectateTargetsUpdated)
local playerDiedEvent = Remotes.Get(Remotes.Names.PlayerDied)
local rollGachaEvent = Remotes.Get(Remotes.Names.RollGacha)
local gachaResultEvent = Remotes.Get(Remotes.Names.GachaResult)
local getGachaCatalogFn = Remotes.Get(Remotes.FunctionNames.GetGachaCatalog)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local DEATH_VIEW_DELAY = 2 -- seconds to watch your own body before spectate engages
local PREV_KEY = Enum.KeyCode.Q
local NEXT_KEY = Enum.KeyCode.E

local spectating = false
local targetNames = {}
local targetIndex = 1
local deathToken = 0 -- generation token: a respawn/new death invalidates pending timers

-- ============================================================
-- Build the GUI once. screenGui.Enabled tracks `spectating`.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SpectateGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

-- ---- Bottom-center spectate bar ----
local bar = Instance.new("Frame")
bar.Size = UDim2.new(0, 620, 0, 50)
bar.Position = UDim2.new(0.5, -310, 1, -70)
bar.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
bar.BackgroundTransparency = 0.2
bar.Parent = screenGui

local barLayout = Instance.new("UIListLayout")
barLayout.FillDirection = Enum.FillDirection.Horizontal
barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
barLayout.VerticalAlignment = Enum.VerticalAlignment.Center
barLayout.Padding = UDim.new(0, 6)
barLayout.SortOrder = Enum.SortOrder.LayoutOrder
barLayout.Parent = bar

local function makeBarButton(text, width, order)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, width, 0, 38)
	button.LayoutOrder = order
	button.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.Gotham
	button.TextScaled = true
	button.Text = text
	button.Parent = bar
	return button
end

local prevButton = makeBarButton("<", 40, 1)

local spectateLabel = Instance.new("TextLabel")
spectateLabel.Size = UDim2.new(0, 240, 0, 38)
spectateLabel.LayoutOrder = 2
spectateLabel.BackgroundTransparency = 1
spectateLabel.TextColor3 = Color3.new(1, 1, 1)
spectateLabel.Font = Enum.Font.Gotham
spectateLabel.TextScaled = true
spectateLabel.Text = "Spectating: ..."
spectateLabel.Parent = bar

local nextButton = makeBarButton(">", 40, 3)
local gachaButton = makeBarButton("Gacha", 90, 4)
local lobbyButton = makeBarButton("Return to Lobby", 150, 5)

-- ---- "Lobby coming soon" toast (placeholder feedback) ----
local toast = Instance.new("TextLabel")
toast.Visible = false
toast.Size = UDim2.new(0, 220, 0, 40)
toast.Position = UDim2.new(0.5, -110, 1, -120)
toast.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
toast.BackgroundTransparency = 0.2
toast.TextColor3 = Color3.new(1, 1, 1)
toast.Font = Enum.Font.Gotham
toast.TextScaled = true
toast.Text = ""
toast.Parent = screenGui

-- ---- Right-side gacha panel (toggled by the Gacha button) ----
local gachaPanel = Instance.new("Frame")
gachaPanel.Visible = false
gachaPanel.Size = UDim2.new(0, 340, 0, 460)
gachaPanel.Position = UDim2.new(1, -360, 0.5, -230)
gachaPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
gachaPanel.BackgroundTransparency = 0.1
gachaPanel.Parent = screenGui

local currencyLabel = Instance.new("TextLabel")
currencyLabel.Size = UDim2.new(1, -10, 0, 26)
currencyLabel.Position = UDim2.new(0, 5, 0, 5)
currencyLabel.BackgroundTransparency = 1
currencyLabel.TextColor3 = Color3.new(1, 1, 1)
currencyLabel.Font = Enum.Font.GothamBold
currencyLabel.TextScaled = true
currencyLabel.TextXAlignment = Enum.TextXAlignment.Left
currencyLabel.Text = "Currency: 0"
currencyLabel.Parent = gachaPanel

local pityLabel = Instance.new("TextLabel")
pityLabel.Size = UDim2.new(1, -10, 0, 22)
pityLabel.Position = UDim2.new(0, 5, 0, 33)
pityLabel.BackgroundTransparency = 1
pityLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
pityLabel.Font = Enum.Font.Gotham
pityLabel.TextScaled = true
pityLabel.TextXAlignment = Enum.TextXAlignment.Left
pityLabel.Text = "Pity: 0/0"
pityLabel.Parent = gachaPanel

local rowHolder = Instance.new("ScrollingFrame")
rowHolder.Size = UDim2.new(1, -10, 1, -105)
rowHolder.Position = UDim2.new(0, 5, 0, 60)
rowHolder.BackgroundTransparency = 1
rowHolder.BorderSizePixel = 0
rowHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
rowHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
rowHolder.ScrollBarThickness = 6
rowHolder.Parent = gachaPanel

local rowLayout = Instance.new("UIListLayout")
rowLayout.Padding = UDim.new(0, 6)
rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
rowLayout.Parent = rowHolder

local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -10, 0, 32)
statusLabel.Position = UDim2.new(0, 5, 1, -37)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(220, 220, 120)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextScaled = true
statusLabel.Text = ""
statusLabel.Parent = gachaPanel

-- ============================================================
-- Gacha panel logic
-- ============================================================
-- Currency label kept live off the replicated attribute - no remote needed.
local function refreshCurrencyLabel()
	currencyLabel.Text = "Currency: " .. tostring(localPlayer:GetAttribute("Currency") or 0)
end
refreshCurrencyLabel()
localPlayer:GetAttributeChangedSignal("Currency"):Connect(refreshCurrencyLabel)

local function clearRows()
	for _, child in ipairs(rowHolder:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

-- Display order follows RARITY, not weight, so a future re-weighted banner
-- still reads Common -> Rare -> Epic. GetOdds builds the array from a
-- nondeterministic pairs loop, so we always re-sort here.
local RARITY_ORDER = { Common = 1, Rare = 2, Epic = 3 }
local function oddsToText(odds)
	local sorted = table.clone(odds)
	table.sort(sorted, function(a, b)
		local ra = RARITY_ORDER[a.variant] or math.huge -- unknown variants sort last
		local rb = RARITY_ORDER[b.variant] or math.huge
		if ra ~= rb then
			return ra < rb
		end
		return a.percent > b.percent -- tie-break by percent descending
	end)
	local parts = {}
	for _, entry in ipairs(sorted) do
		table.insert(parts, entry.variant .. " " .. tostring(entry.percent) .. "%")
	end
	return table.concat(parts, " / ")
end

local function refreshCatalog()
	local catalog = getGachaCatalogFn:InvokeServer()
	if not catalog then
		return
	end

	refreshCurrencyLabel()
	pityLabel.Text = "Pity: " .. tostring(catalog.pityRollsUsed) .. "/" .. tostring(catalog.pityThreshold)

	clearRows()
	for i, entry in ipairs(catalog.powerups) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -6, 0, 92)
		row.LayoutOrder = i
		row.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
		row.Parent = rowHolder

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -10, 0, 22)
		nameLabel.Position = UDim2.new(0, 5, 0, 3)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.new(1, 1, 1)
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextScaled = true
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Text = entry.displayName .. "  [" .. tostring(entry.team) .. "]"
		nameLabel.Parent = row

		local ownedLabel = Instance.new("TextLabel")
		ownedLabel.Size = UDim2.new(1, -10, 0, 18)
		ownedLabel.Position = UDim2.new(0, 5, 0, 26)
		ownedLabel.BackgroundTransparency = 1
		ownedLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		ownedLabel.Font = Enum.Font.Gotham
		ownedLabel.TextScaled = true
		ownedLabel.TextXAlignment = Enum.TextXAlignment.Left
		ownedLabel.Text = entry.ownedVariant and ("Owned: " .. entry.ownedVariant) or "Not owned"
		ownedLabel.Parent = row

		local oddsLabel = Instance.new("TextLabel")
		oddsLabel.Size = UDim2.new(1, -10, 0, 18)
		oddsLabel.Position = UDim2.new(0, 5, 0, 45)
		oddsLabel.BackgroundTransparency = 1
		oddsLabel.TextColor3 = Color3.fromRGB(170, 170, 170)
		oddsLabel.Font = Enum.Font.Gotham
		oddsLabel.TextScaled = true
		oddsLabel.TextXAlignment = Enum.TextXAlignment.Left
		oddsLabel.Text = oddsToText(entry.odds)
		oddsLabel.Parent = row

		local rollButton = Instance.new("TextButton")
		rollButton.Size = UDim2.new(0, 130, 0, 22)
		rollButton.Position = UDim2.new(0, 5, 0, 66)
		rollButton.BackgroundColor3 = Color3.fromRGB(70, 90, 70)
		rollButton.TextColor3 = Color3.new(1, 1, 1)
		rollButton.Font = Enum.Font.Gotham
		rollButton.TextScaled = true
		rollButton.Text = "Roll (" .. tostring(catalog.cost) .. ")"
		rollButton.Parent = row

		rollButton.MouseButton1Click:Connect(function()
			rollGachaEvent:FireServer(entry.id)
		end)
	end
end

gachaButton.MouseButton1Click:Connect(function()
	gachaPanel.Visible = not gachaPanel.Visible
	if gachaPanel.Visible then
		-- Refresh invokes the server (yields) - spawn so the click handler returns.
		task.spawn(refreshCatalog)
	end
end)

gachaResultEvent.OnClientEvent:Connect(function(success, result, variant, rollStatus)
	if not success then
		if result == "InsufficientCurrency" then
			statusLabel.Text = "Not enough currency"
		else
			statusLabel.Text = tostring(result)
		end
	else
		-- rollStatus is GachaService.Roll's 4th return: "New" | "Upgraded" |
		-- "Duplicate". Anything else/nil means the value is missing - show no
		-- suffix rather than guessing a label from it.
		local note
		if rollStatus == "New" then
			note = "New unlock"
		elseif rollStatus == "Upgraded" then
			note = "Upgraded"
		elseif rollStatus == "Duplicate" then
			note = "Duplicate"
		end
		if note then
			statusLabel.Text = "Rolled " .. tostring(variant) .. "! " .. note
		else
			statusLabel.Text = "Rolled " .. tostring(variant) .. "!"
		end
	end

	-- Re-run so Owned + Pity reflect the roll.
	task.spawn(refreshCatalog)
end)

-- PLACEHOLDER: Return to Lobby stands in for the future lobby teleport
-- (TeleportService). Replace this toast with the real teleport flow once the
-- lobby place exists.
local lobbyToastToken = 0
lobbyButton.MouseButton1Click:Connect(function()
	toast.Text = "Lobby coming soon"
	toast.Visible = true
	lobbyToastToken = lobbyToastToken + 1
	local myToken = lobbyToastToken
	task.delay(2, function()
		-- Token guard so rapid clicks don't stack hides that close a newer toast.
		if myToken == lobbyToastToken then
			toast.Visible = false
		end
	end)
end)

-- ============================================================
-- Spectate mechanics
-- ============================================================
local function applyTarget()
	if #targetNames == 0 then
		spectateLabel.Text = "Spectating: (no targets)"
		return
	end

	-- Try each target once from targetIndex; stop after one full loop so an
	-- all-invalid list can never spin forever.
	for _ = 1, #targetNames do
		local name = targetNames[targetIndex]
		local target = name and Players:FindFirstChild(name)
		local character = target and target.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			workspace.CurrentCamera.CameraSubject = humanoid -- CameraType stays Custom = orbit follow
			spectateLabel.Text = "Spectating: " .. name
			return
		end
		targetIndex = targetIndex % #targetNames + 1
	end

	-- Nothing valid to show; leave the camera where it is.
	spectateLabel.Text = "Spectating: (no targets)"
end

local function enterSpectate()
	spectating = true
	screenGui.Enabled = true
	targetIndex = 1
	applyTarget()
end

local function cycle(direction)
	if #targetNames == 0 then
		return
	end
	targetIndex = (targetIndex - 1 + direction) % #targetNames + 1
	applyTarget()
end

prevButton.MouseButton1Click:Connect(function()
	cycle(-1)
end)
nextButton.MouseButton1Click:Connect(function()
	cycle(1)
end)

-- ============================================================
-- Remote listeners
-- ============================================================
spectateTargetsEvent.OnClientEvent:Connect(function(names)
	local previousName = targetNames[targetIndex]
	targetNames = names or {} -- always store, even before death

	if spectating then
		if #targetNames == 0 then
			return -- nobody left to watch; leave the camera where it is
		end

		-- Keep watching the same player if they're still alive; otherwise
		-- advance to the next valid target.
		local found = false
		for i, name in ipairs(targetNames) do
			if name == previousName then
				targetIndex = i
				found = true
				break
			end
		end
		if not found then
			targetIndex = 1
			applyTarget()
		end
	end
end)

playerDiedEvent.OnClientEvent:Connect(function()
	deathToken = deathToken + 1
	local myToken = deathToken
	task.delay(DEATH_VIEW_DELAY, function()
		-- Only engage if no respawn/new death happened in the interim.
		if myToken == deathToken and not spectating then
			enterSpectate()
		end
	end)
end)

localPlayer.CharacterAdded:Connect(function(character)
	deathToken = deathToken + 1 -- cancel any pending death-view timer
	spectating = false
	screenGui.Enabled = false
	gachaPanel.Visible = false

	local humanoid = character:WaitForChild("Humanoid")
	workspace.CurrentCamera.CameraSubject = humanoid
end)

-- ============================================================
-- Q/E cycle targets while spectating
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not spectating then
		return
	end
	if input.KeyCode == PREV_KEY then
		cycle(-1)
	elseif input.KeyCode == NEXT_KEY then
		cycle(1)
	end
end)
