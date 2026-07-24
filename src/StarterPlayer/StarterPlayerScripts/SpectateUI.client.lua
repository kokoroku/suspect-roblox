--[[
	SpectateUI.client.lua
	Dead-player spectate experience, built entirely in code (no manually placed
	Studio GUI objects) so it stays version-controlled. Deliberately rough - full
	styling comes in the UI rehaul pass. No animations.

	Lifecycle:
	  - Server fires PlayerDied when this player dies. After DEATH_VIEW_DELAY
	    seconds (long enough to watch your own body drop) spectate engages: the
	    camera follows a living player and a bottom bar lets you cycle targets
	    (< / > buttons or Q/E) or hit a placeholder Return to Lobby button.
	    (The gacha panel used to live here; it is a tab in the always-available
	    hub window now - see HubUI.client.lua.)
	  - The server keeps the target list fresh via SpectateTargetsUpdated (only
	    ever sent to dead players).
	  - Spectate ends when the local character respawns (CharacterAdded), which
	    happens on every match restart - no MatchEnded handling needed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local spectateTargetsEvent = Remotes.Get(Remotes.Names.SpectateTargetsUpdated)
local playerDiedEvent = Remotes.Get(Remotes.Names.PlayerDied)
local roundStatusEvent = Remotes.Get(Remotes.Names.RoundStatus)

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

-- ---- Ghost control bar, sitting DIRECTLY ABOVE the persistent bottom bar ----
local bar = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(620, 46),
	UDim2.new(0.5, 0, 1, -56),
	Vector2.new(0.5, 1)
)

local barLayout = Instance.new("UIListLayout")
barLayout.FillDirection = Enum.FillDirection.Horizontal
barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
barLayout.VerticalAlignment = Enum.VerticalAlignment.Center
barLayout.Padding = UDim.new(0, UIStyle.Pad)
barLayout.SortOrder = Enum.SortOrder.LayoutOrder
barLayout.Parent = bar

local function makeBarButton(text, width, order)
	local button = UIStyle.MakeButton(bar, text)
	button.Size = UDim2.fromOffset(width, 32)
	button.LayoutOrder = order
	return button
end

local prevButton = makeBarButton("<", 36, 1)

local spectateLabel = UIStyle.MakeLabel(bar, "Spectating: ...")
spectateLabel.Size = UDim2.fromOffset(220, 32)
spectateLabel.LayoutOrder = 2
spectateLabel.TextXAlignment = Enum.TextXAlignment.Center

local nextButton = makeBarButton(">", 36, 3)

-- The only keybind legend in the game so far - the hub is reachable while dead,
-- and this bar is the one place a ghost is already looking.
local hintLabel = UIStyle.MakeLabel(bar, "G - Store   L - Inventory", true)
hintLabel.Size = UDim2.fromOffset(150, 32)
hintLabel.LayoutOrder = 4
hintLabel.TextSize = 12
hintLabel.TextXAlignment = Enum.TextXAlignment.Center

local lobbyButton = makeBarButton("Return to Lobby", 140, 5)

-- ---- "Lobby coming soon" toast (placeholder feedback) ----
local toast = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(220, 36),
	UDim2.new(0.5, 0, 1, -110),
	Vector2.new(0.5, 1)
)
toast.Visible = false

local toastLabel = UIStyle.MakeLabel(toast, "")
toastLabel.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, 0)
toastLabel.Position = UDim2.new(0, UIStyle.Pad, 0, 0)
toastLabel.TextXAlignment = Enum.TextXAlignment.Center

-- PLACEHOLDER: Return to Lobby stands in for the future lobby teleport
-- (TeleportService). Replace this toast with the real teleport flow once the
-- lobby place exists.
local lobbyToastToken = 0
lobbyButton.MouseButton1Click:Connect(function()
	toastLabel.Text = "Lobby coming soon"
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
		-- start from the top.
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
		end

		-- Clamp into range and re-apply. This also covers the list arriving AFTER
		-- spectate engaged - e.g. a late joiner's empty -> populated update.
		if targetIndex > #targetNames then
			targetIndex = 1
		end
		applyTarget()
	end
end)

roundStatusEvent.OnClientEvent:Connect(function(data)
	-- Late-joiner path: PlayerDied never fires for them, so the server's
	-- spectator flag is what drops them into spectate. The Character == nil guard
	-- means this can never hijack a living player's camera.
	if data.state == "InProgress" and data.spectator and not spectating and localPlayer.Character == nil then
		enterSpectate()
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
