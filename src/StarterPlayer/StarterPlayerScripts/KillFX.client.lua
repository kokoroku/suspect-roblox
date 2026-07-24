--[[
	KillFX.client.lua
	Client-side juice for kills, layered on top of the existing kill/death flow -
	it never gates or replaces any of it. Three audiences:

	  - KILLER (on KillFeedback): a quick red vignette + a small FOV punch.
	  - VICTIM (on PlayerDied - always the local player's OWN death): a brief red
	    full-screen flash before the existing death/spectate flow takes over.
	    DeathState is NOT touched; this only layers on top.
	  - IMPOSTOR cooldown chip (via RoleAssigned): a small pixel "F" keycap to the
	    LEFT of the powerup slots. On a kill it runs a darkening sweep + countdown
	    over the cooldown the server sends, then clears. Hidden for non-impostors.

	Everything transient is guarded (tween-cancel or a Heartbeat token) and reset on
	CharacterAdded / MatchEnded so nothing lingers into the next life or match.

	Accepted (do NOT "fix"): the chip only shows a countdown AFTER the first kill -
	it has no match-start readiness signal, which is fine for now.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))
local killFeedbackEvent = Remotes.Get(Remotes.Names.KillFeedback)
local playerDiedEvent = Remotes.Get(Remotes.Names.PlayerDied)
local roleAssignedEvent = Remotes.Get(Remotes.Names.RoleAssigned)
local matchEndedEvent = Remotes.Get(Remotes.Names.MatchEnded)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local IMPOSTOR_ROLE = "Impostor"
-- PressStart2P + near-white border, matched to PromptUI's keycap look.
local PIXEL_FONT = "rbxasset://fonts/families/PressStart2P.json"
local PIXEL_FONTFACE = Font.new(PIXEL_FONT)
local NEAR_WHITE = Color3.fromRGB(235, 235, 240)
local BLACK = Color3.fromRGB(0, 0, 0)

-- Bottom-right layout, mirroring PowerupHUD so the chip sits just LEFT of its two
-- 64px slots (SLOT*2 + GAP = 136 wide, 10px from the corner).
local EDGE = 10
local SLOTS_WIDTH = 64 * 2 + 8
local CHIP_GAP = 8
local CHIP_W = 48
local CHIP_H = 64
local KEY_SIZE = 34
local SHADOW_OFFSET = 3

local DEFAULT_FOV = (workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView) or 70

-- ============================================================
-- Full-screen effect layer (killer vignette + victim flash), above the HUD.
-- ============================================================
local fxGui = Instance.new("ScreenGui")
fxGui.Name = "KillFXGui"
fxGui.ResetOnSpawn = false
fxGui.IgnoreGuiInset = true
fxGui.DisplayOrder = 100
fxGui.Parent = playerGui

local vignette = Instance.new("Frame")
vignette.Size = UDim2.fromScale(1, 1)
vignette.BackgroundColor3 = Color3.fromRGB(170, 15, 15)
vignette.BackgroundTransparency = 1
vignette.BorderSizePixel = 0
vignette.ZIndex = 1
vignette.Parent = fxGui

local victimFlash = Instance.new("Frame")
victimFlash.Size = UDim2.fromScale(1, 1)
victimFlash.BackgroundColor3 = Color3.fromRGB(200, 25, 25)
victimFlash.BackgroundTransparency = 1
victimFlash.BorderSizePixel = 0
victimFlash.ZIndex = 2
victimFlash.Parent = fxGui

-- ============================================================
-- Kill cooldown chip (impostor only), in the HUD layer.
-- ============================================================
local chipGui = Instance.new("ScreenGui")
chipGui.Name = "KillCooldownGui"
chipGui.ResetOnSpawn = false
chipGui.DisplayOrder = 5
chipGui.Enabled = false -- shown only once we learn we're the impostor
chipGui.Parent = playerGui

local chip = UIStyle.MakePanel(
	chipGui,
	UDim2.fromOffset(CHIP_W, CHIP_H),
	UDim2.new(1, -(EDGE + SLOTS_WIDTH + CHIP_GAP), 1, -EDGE),
	Vector2.new(1, 1)
)

-- Pixel keycap, consistent with PromptUI: dark face, 3px near-white stroke, a
-- chunky black drop-shadow, the letter in Accent. No UICorner on these.
local keyShadow = Instance.new("Frame")
keyShadow.AnchorPoint = Vector2.new(0.5, 0.5)
keyShadow.Size = UDim2.fromOffset(KEY_SIZE, KEY_SIZE)
keyShadow.Position = UDim2.new(0.5, SHADOW_OFFSET, 0.5, SHADOW_OFFSET)
keyShadow.BackgroundColor3 = BLACK
keyShadow.BorderSizePixel = 0
keyShadow.ZIndex = 2
keyShadow.Parent = chip

local keycap = Instance.new("Frame")
keycap.AnchorPoint = Vector2.new(0.5, 0.5)
keycap.Size = UDim2.fromOffset(KEY_SIZE, KEY_SIZE)
keycap.Position = UDim2.fromScale(0.5, 0.5)
keycap.BackgroundColor3 = UIStyle.Colors.Bg
keycap.BorderSizePixel = 0
keycap.ClipsDescendants = true
keycap.ZIndex = 3
keycap.Parent = chip

local keyBorder = Instance.new("UIStroke")
keyBorder.Thickness = 3
keyBorder.Color = NEAR_WHITE
keyBorder.Parent = keycap

local keyLetter = Instance.new("TextLabel")
keyLetter.BackgroundTransparency = 1
keyLetter.Size = UDim2.fromScale(1, 1)
keyLetter.FontFace = PIXEL_FONTFACE
keyLetter.TextScaled = true
keyLetter.TextColor3 = UIStyle.Colors.Accent
keyLetter.TextStrokeColor3 = BLACK
keyLetter.TextStrokeTransparency = 0
keyLetter.Text = ClientSettings.GetKey("Kill").Name -- the current Kill binding
keyLetter.ZIndex = 4
keyLetter.Parent = keycap

local letterPad = Instance.new("UIPadding")
letterPad.PaddingTop = UDim.new(0, 5)
letterPad.PaddingBottom = UDim.new(0, 5)
letterPad.PaddingLeft = UDim.new(0, 5)
letterPad.PaddingRight = UDim.new(0, 5)
letterPad.Parent = keyLetter

-- Darkening sweep over the keycap: anchored to the bottom, its height shrinks from
-- full to zero across the cooldown, so the cap "fills back in" from the top down.
local cooldownSweep = Instance.new("Frame")
cooldownSweep.AnchorPoint = Vector2.new(0.5, 1)
cooldownSweep.Position = UDim2.fromScale(0.5, 1)
cooldownSweep.Size = UDim2.fromScale(1, 1)
cooldownSweep.BackgroundColor3 = BLACK
cooldownSweep.BackgroundTransparency = 0.35
cooldownSweep.BorderSizePixel = 0
cooldownSweep.Visible = false
cooldownSweep.ZIndex = 5
cooldownSweep.Parent = keycap

local cooldownNumber = Instance.new("TextLabel")
cooldownNumber.BackgroundTransparency = 1
cooldownNumber.Size = UDim2.fromScale(1, 1)
cooldownNumber.FontFace = PIXEL_FONTFACE
cooldownNumber.TextScaled = true
cooldownNumber.TextColor3 = UIStyle.Colors.TextPrimary
cooldownNumber.TextStrokeColor3 = BLACK
cooldownNumber.TextStrokeTransparency = 0
cooldownNumber.Text = ""
cooldownNumber.Visible = false
cooldownNumber.ZIndex = 6
cooldownNumber.Parent = keycap

local numberPad = Instance.new("UIPadding")
numberPad.PaddingTop = UDim.new(0, 6)
numberPad.PaddingBottom = UDim.new(0, 6)
numberPad.PaddingLeft = UDim.new(0, 6)
numberPad.PaddingRight = UDim.new(0, 6)
numberPad.Parent = cooldownNumber

-- ============================================================
-- Transient effect helpers (guarded + resettable).
-- ============================================================
local vignetteTween = nil
local fovTween = nil
local flashTween = nil
local cooldownToken = 0

local function playVignette()
	if vignetteTween then
		vignetteTween:Cancel()
	end
	vignette.BackgroundTransparency = 0.55
	vignetteTween = TweenService:Create(vignette, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
	vignetteTween:Play()
end

local function punchFov()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	if fovTween then
		fovTween:Cancel()
	end
	camera.FieldOfView = DEFAULT_FOV + 4
	fovTween = TweenService:Create(camera, TweenInfo.new(0.25), { FieldOfView = DEFAULT_FOV })
	fovTween:Play()
end

local function playVictimFlash()
	if flashTween then
		flashTween:Cancel()
	end
	victimFlash.BackgroundTransparency = 0.4
	flashTween = TweenService:Create(victimFlash, TweenInfo.new(0.5), { BackgroundTransparency = 1 })
	flashTween:Play()
end

-- Runs the sweep + countdown on the chip. Token-guarded so a new kill (or a
-- reset) supersedes any live loop cleanly.
local function startCooldownSweep(seconds)
	cooldownToken += 1
	local myToken = cooldownToken
	cooldownSweep.Size = UDim2.fromScale(1, 1)
	cooldownSweep.Visible = true
	cooldownNumber.Visible = true
	if type(seconds) ~= "number" or seconds <= 0 then
		cooldownSweep.Visible = false
		cooldownNumber.Visible = false
		return
	end
	local elapsed = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if myToken ~= cooldownToken then
			conn:Disconnect() -- superseded
			return
		end
		elapsed += dt
		local frac = math.clamp(1 - elapsed / seconds, 0, 1)
		cooldownSweep.Size = UDim2.fromScale(1, frac)
		cooldownNumber.Text = tostring(math.ceil(math.max(seconds - elapsed, 0)))
		if elapsed >= seconds then
			conn:Disconnect()
			cooldownSweep.Visible = false
			cooldownNumber.Visible = false
		end
	end)
end

-- Clears the chip's cooldown display (bumps the token to kill any live loop).
local function clearCooldown()
	cooldownToken += 1
	cooldownSweep.Visible = false
	cooldownNumber.Visible = false
end

-- Resets everything transient - used on respawn and match end so no effect bleeds
-- into the next life/match.
local function resetTransient()
	if vignetteTween then
		vignetteTween:Cancel()
		vignetteTween = nil
	end
	vignette.BackgroundTransparency = 1
	if flashTween then
		flashTween:Cancel()
		flashTween = nil
	end
	victimFlash.BackgroundTransparency = 1
	if fovTween then
		fovTween:Cancel()
		fovTween = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = DEFAULT_FOV
	end
	clearCooldown()
end

-- ============================================================
-- Remote wiring.
-- ============================================================
killFeedbackEvent.OnClientEvent:Connect(function(payload)
	-- Reduce-effects skips the killer's FLAIR (vignette + FOV punch) entirely. The
	-- victim flash is deliberately NOT gated here - it communicates death, not
	-- flair - and the cooldown chip is informational, so both always run.
	if not ClientSettings.GetReduceEffects() then
		playVignette()
		punchFov()
	end
	-- The chip only exists for impostors, who are the only ones that receive this.
	if chipGui.Enabled then
		startCooldownSweep(payload and payload.cooldown)
	end
end)

-- PlayerDied only ever fires to the dying player themselves, so this is always our
-- own death. Flash first; the existing death/spectate flow runs independently.
playerDiedEvent.OnClientEvent:Connect(function()
	playVictimFlash()
end)

-- Role decides whether the chip exists at all; a new role each match re-decides.
roleAssignedEvent.OnClientEvent:Connect(function(role)
	clearCooldown()
	chipGui.Enabled = (role == IMPOSTOR_ROLE)
end)

-- Keep the chip's keycap letter on the current Kill binding.
ClientSettings.Changed.Event:Connect(function(settingName)
	if settingName == "Kill" then
		keyLetter.Text = ClientSettings.GetKey("Kill").Name
	end
end)

matchEndedEvent.OnClientEvent:Connect(function()
	resetTransient()
	chipGui.Enabled = false
end)

localPlayer.CharacterAdded:Connect(function()
	resetTransient()
end)
