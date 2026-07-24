--[[
	PromptUI.client.lua
	The pixel keybind renderer for world interactables. Every world ProximityPrompt
	is switched to ProximityPromptStyle.Custom server-side (task/emergency/sabotage/
	body handlers), which suppresses the default Roblox prompt UI - this script draws
	the replacement: a small floating pixel keycap over the interactable.

	Driven entirely off ProximityPromptService, so it covers EVERY custom prompt in
	the world with no per-prompt wiring:
	  - PromptShown(prompt)  -> build one BillboardGui adorned to prompt.Parent
	  - PromptHidden(prompt) -> destroy it
	  - PromptButtonHoldBegan/Ended -> animate the keycap fill for hold prompts

	Deliberately a PIXEL accent layer: a blocky PressStart2P keycap with hard edges
	and a chunky offset shadow, contrasting the Montserrat/rounded panel UI on
	purpose. NO UICorner anywhere in this file.

	Accepted current behavior (do NOT "fix"): the keycap always shows the KEYBOARD
	keycode name (desktop-first). The per-platform mobile input pass replaces this
	with a touch glyph later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")

local UIStyle = require(ReplicatedStorage.Modules.UIStyle)

-- PressStart2P ships WITH the engine (like Montserrat), so this is not a
-- marketplace dependency. If it ever fails to resolve in-game, THIS is the single
-- string to swap.
local PIXEL_FONT = "rbxasset://fonts/families/PressStart2P.json"
local PIXEL_FONTFACE = Font.new(PIXEL_FONT)

local KEY_SIZE = 34 -- keycap side, pixels
local SHADOW_OFFSET = 3 -- chunky pixel drop-shadow, pixels
local ACCENT = UIStyle.Colors.Accent
local KEY_BG = UIStyle.Colors.Bg -- dark keycap face
local NEAR_WHITE = Color3.fromRGB(235, 235, 240) -- keycap border
local BLACK = Color3.fromRGB(0, 0, 0)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- One entry per live prompt: { gui, fill, holdDuration, tween }.
local active = {}

-- Cancel and drop a running fill tween so nothing lingers on a destroyed frame.
local function stopTween(entry)
	if entry.tween then
		entry.tween:Cancel()
		entry.tween = nil
	end
end

local function buildBillboard(prompt)
	local adornee = prompt.Parent
	-- Guard: a prompt can be shown against a part that's already being torn down.
	if not adornee or not adornee:IsA("BasePart") then
		return nil
	end

	local hasLabel = prompt.ActionText ~= nil and prompt.ActionText ~= ""

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PromptUI"
	billboard.Adornee = adornee
	billboard.Size = UDim2.new(0, 140, 0, 64)
	billboard.StudsOffset = Vector3.new(0, 2.2, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = math.huge
	billboard.ResetOnSpawn = false
	billboard.Parent = playerGui

	-- ---- Action label on top (pixel shadow look: solid black outline) ----
	-- Hidden when the prompt has no ActionText, so the keycap can center alone.
	if hasLabel then
		local label = Instance.new("TextLabel")
		label.Name = "Action"
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 0, 18)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.FontFace = PIXEL_FONTFACE
		label.TextSize = 10
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextStrokeColor3 = BLACK
		label.TextStrokeTransparency = 0 -- solid black outline = the pixel shadow
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.TextWrapped = true
		label.Text = prompt.ActionText
		label.Parent = billboard
	end

	-- ---- Keycap: centered horizontally; vertically it sits under the label when
	-- there is one, otherwise it centers in the billboard. ----
	local keyY = hasLabel and 24 or math.floor((64 - KEY_SIZE) / 2)

	-- Chunky offset drop-shadow BEHIND the keycap (solid black, shifted +3,+3).
	local shadow = Instance.new("Frame")
	shadow.Name = "KeyShadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0)
	shadow.Size = UDim2.fromOffset(KEY_SIZE, KEY_SIZE)
	shadow.Position = UDim2.new(0.5, SHADOW_OFFSET, 0, keyY + SHADOW_OFFSET)
	shadow.BackgroundColor3 = BLACK
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 1
	shadow.Parent = billboard

	-- Keycap face.
	local keycap = Instance.new("Frame")
	keycap.Name = "Keycap"
	keycap.AnchorPoint = Vector2.new(0.5, 0)
	keycap.Size = UDim2.fromOffset(KEY_SIZE, KEY_SIZE)
	keycap.Position = UDim2.new(0.5, 0, 0, keyY)
	keycap.BackgroundColor3 = KEY_BG
	keycap.BorderSizePixel = 0
	keycap.ClipsDescendants = true -- keeps the rising fill inside the cap
	keycap.ZIndex = 2
	keycap.Parent = billboard

	local border = Instance.new("UIStroke")
	border.Thickness = 3
	border.Color = NEAR_WHITE
	border.Parent = keycap

	-- Hold fill: rises from the bottom to full over HoldDuration, behind the letter.
	local fill = Instance.new("Frame")
	fill.Name = "HoldFill"
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.new(0, 0, 1, 0)
	fill.Size = UDim2.new(1, 0, 0, 0)
	fill.BackgroundColor3 = ACCENT
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = keycap

	-- Key letter, on top of the fill.
	local keyName = prompt.KeyboardKeyCode and prompt.KeyboardKeyCode.Name or ""
	local letter = Instance.new("TextLabel")
	letter.Name = "Key"
	letter.BackgroundTransparency = 1
	letter.Size = UDim2.new(1, 0, 1, 0)
	letter.FontFace = PIXEL_FONTFACE
	letter.TextScaled = true
	letter.TextColor3 = ACCENT
	letter.TextStrokeColor3 = BLACK
	letter.TextStrokeTransparency = 0
	letter.TextXAlignment = Enum.TextXAlignment.Center
	letter.TextYAlignment = Enum.TextYAlignment.Center
	letter.ZIndex = 4
	letter.Text = keyName
	letter.Parent = keycap

	-- Keep the scaled letter from swallowing the whole cap.
	local letterPad = Instance.new("UIPadding")
	letterPad.PaddingTop = UDim.new(0, 5)
	letterPad.PaddingBottom = UDim.new(0, 5)
	letterPad.PaddingLeft = UDim.new(0, 5)
	letterPad.PaddingRight = UDim.new(0, 5)
	letterPad.Parent = letter

	return billboard, fill
end

ProximityPromptService.PromptShown:Connect(function(prompt)
	-- One billboard per prompt; ignore a duplicate shown event.
	if active[prompt] then
		return
	end
	local gui, fill = buildBillboard(prompt)
	if not gui then
		return
	end
	active[prompt] = { gui = gui, fill = fill, holdDuration = prompt.HoldDuration, tween = nil }
end)

ProximityPromptService.PromptHidden:Connect(function(prompt)
	local entry = active[prompt]
	if not entry then
		return
	end
	stopTween(entry)
	if entry.gui then
		entry.gui:Destroy()
	end
	active[prompt] = nil
end)

ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
	local entry = active[prompt]
	-- Zero-duration prompts never show a fill (nothing to fill over).
	if not entry or not entry.fill or entry.holdDuration <= 0 then
		return
	end
	stopTween(entry)
	entry.fill.Size = UDim2.new(1, 0, 0, 0)
	local tween = TweenService:Create(
		entry.fill,
		TweenInfo.new(entry.holdDuration, Enum.EasingStyle.Linear),
		{ Size = UDim2.new(1, 0, 1, 0) }
	)
	entry.tween = tween
	tween:Play()
end)

ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt)
	local entry = active[prompt]
	if not entry or not entry.fill then
		return
	end
	stopTween(entry)
	entry.fill.Size = UDim2.new(1, 0, 0, 0)
end)
