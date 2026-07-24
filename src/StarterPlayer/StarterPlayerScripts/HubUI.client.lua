--[[
	HubUI.client.lua
	The ONE player-facing window: a tabbed hub holding Loadout, Gacha and Store.
	Replaces the old standalone LoadoutUI and GachaUI panels (both deleted) - all
	three surfaces now share one frame, one style and one open/close rule.

	Built entirely in code from UIStyle (no manually placed Studio GUI objects) so
	it stays version-controlled. Functionally final, visually rough on purpose:
	the art pass re-skins UIStyle, not this file.

	Opening:
	  - Keys G (Store) and L (Inventory), gameProcessed guarded.
	  - The BottomBar buttons, via the "HubOpen" BindableEvent this script creates
	    and parents to itself (payload: the tab name).
	  Toggle rule for both paths - closed opens on that tab, open on a DIFFERENT
	  tab switches, open on the SAME tab closes. The X always closes.

	Usable while dead: ghosts roll and re-equip through this same window. Closed
	on meeting start (the same MeetingStarted remote MeetingUI listens to).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)

local setLoadoutEvent = Remotes.Get(Remotes.Names.SetLoadout)
local loadoutResultEvent = Remotes.Get(Remotes.Names.LoadoutResult)
local loadoutAppliedEvent = Remotes.Get(Remotes.Names.LoadoutApplied)
local rollGachaEvent = Remotes.Get(Remotes.Names.RollGacha)
local gachaResultEvent = Remotes.Get(Remotes.Names.GachaResult)
local upgradePowerupEvent = Remotes.Get(Remotes.Names.UpgradePowerup)
local upgradeResultEvent = Remotes.Get(Remotes.Names.UpgradeResult)
local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)
local getGachaCatalogFn = Remotes.Get(Remotes.FunctionNames.GetGachaCatalog)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Created FIRST so BottomBar's WaitForChild resolves as early as possible.
local hubOpenEvent = Instance.new("BindableEvent")
hubOpenEvent.Name = "HubOpen"
hubOpenEvent.Parent = script

local MAX_SLOTS = 2
-- Two tabs. Store = Shop placeholder + the gacha; Inventory = loadout +
-- Cosmetics placeholder. Each tab is a stack of sections, not one screen.
local TABS = { "Store", "Inventory" }

-- ============================================================
-- Module state. Kept out here so a tab rebuild is cheap - switching tabs
-- destroys and recreates only the instances, never the data.
-- ============================================================
local currentTab = nil

-- Loadout
local activeLoadout = {} -- ids the server locked in for the CURRENT match
local selected = {} -- ids picked for the next save (max MAX_SLOTS)
-- The last selection this client saved successfully; preselected on open.
-- Client memory only - the server's pending table is the truth and re-validates.
local lastSaved = {}
local ownedList = {} -- [{ id, displayName, tier, rarity }]
local ownedById = {} -- id -> { displayName, tier }
local loadoutRefs = nil -- live instances while the Loadout tab is built

-- Gacha
local catalogById = {} -- id -> catalog entry, so results can resolve names
local gachaRefs = nil -- live instances while the Gacha tab is built
-- Reveal animation state. rollToken invalidates an in-flight sequence (a newer
-- roll, or a tab rebuild); rollBusy gates the button between click and landing.
local rollToken = 0
local rollBusy = false
local rollCost = 50 -- last cost the catalog reported, for restoring the button

local RARITY_COLOR = {
	Common = UIStyle.Colors.RarityCommon,
	Rare = UIStyle.Colors.RarityRare,
	Epic = UIStyle.Colors.RarityEpic,
}

-- ============================================================
-- Window chrome, built once.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "HubGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local closeHub -- forward declared; MakeHeader needs it before openTab exists

-- FIXED size and centered, deliberately NOT resizable: the resize input layer
-- was fighting this window and shifting it around. The size below is chosen to
-- be comfortable as-is (several catalog rows visible without any adjustment),
-- and nothing in this file ever writes Size or reads a remembered geometry.
local HUB_SIZE = UDim2.fromOffset(540, 480)
local HUB_POSITION = UDim2.new(0.5, 0, 0.5, 0)

local panel = UIStyle.MakePanel(screenGui, HUB_SIZE, HUB_POSITION, Vector2.new(0.5, 0.5))
-- Sinks clicks so nothing inside the window reaches a world ProximityPrompt.
panel.Active = true

local headerStrip = UIStyle.MakeHeader(panel, "Suspect", function()
	closeHub()
end)

-- The header stays draggable: MakeDraggable only ever moves the panel from an
-- InputBegan on this strip followed by pointer movement, so opening the hub or
-- switching tabs cannot move it.
UIStyle.MakeDraggable(panel, headerStrip)

local tabRow = Instance.new("Frame")
tabRow.Size = UDim2.new(1, -UIStyle.Pad * 2, 0, 32)
tabRow.Position = UDim2.new(0, UIStyle.Pad, 0, 44)
tabRow.BackgroundTransparency = 1
tabRow.Parent = panel

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, UIStyle.Pad)
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.Parent = tabRow

local content = Instance.new("Frame")
content.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, -84 - UIStyle.Pad)
content.Position = UDim2.new(0, UIStyle.Pad, 0, 84)
content.BackgroundTransparency = 1
content.Parent = panel

local tabButtons = {}

-- ============================================================
-- Shared helpers
-- ============================================================
local function clearContent()
	loadoutRefs = nil
	gachaRefs = nil
	-- Any reveal sequence still running belongs to instances about to die: kill
	-- its token so it stops touching them, and free the Roll button for the next
	-- build. Destroying the content also sweeps the card's transient Sounds.
	rollToken += 1
	rollBusy = false
	for _, child in ipairs(content:GetChildren()) do
		child:Destroy()
	end
end

-- A transparent block inside the content frame. Tabs are built as a stack of
-- these, each section positioning its own children from its own top edge.
local function makeSection(position, size)
	local frame = Instance.new("Frame")
	frame.Position = position
	frame.Size = size
	frame.BackgroundTransparency = 1
	frame.Parent = content
	return frame
end

local function makeScroller(parent, position, size)
	local scroller = Instance.new("ScrollingFrame")
	scroller.Position = position
	scroller.Size = size
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.ScrollBarThickness = 4
	scroller.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroller

	return scroller
end

-- ============================================================
-- LOADOUT TAB
-- ============================================================
local function loadoutSetStatus(text)
	if loadoutRefs then
		loadoutRefs.status.Text = text
	end
end

local function refreshActiveLabel()
	if not loadoutRefs then
		return
	end
	if #activeLoadout == 0 then
		loadoutRefs.active.Text = "Active this match: none"
		return
	end
	local names = {}
	for _, id in ipairs(activeLoadout) do
		local info = ownedById[id]
		table.insert(names, info and info.displayName or id)
	end
	loadoutRefs.active.Text = "Active this match: " .. table.concat(names, ", ")
end

local function isSelected(id)
	return table.find(selected, id) ~= nil
end

local function renderLoadoutRows()
	if not loadoutRefs then
		return
	end
	for _, child in ipairs(loadoutRefs.rows:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for i, entry in ipairs(ownedList) do
		local row = UIStyle.MakeButton(loadoutRefs.rows, "  " .. entry.displayName .. "   Tier " .. tostring(entry.tier))
		row.Size = UDim2.new(1, -6, 0, 30)
		row.LayoutOrder = i
		row.TextXAlignment = Enum.TextXAlignment.Left
		row.TextColor3 = RARITY_COLOR[entry.rarity] or UIStyle.Colors.TextPrimary
		-- Selection goes through the style layer so hovering a selected row turns
		-- it translucent instead of wiping the green.
		UIStyle.SetButtonSelected(row, isSelected(entry.id), UIStyle.Colors.Selected)

		row.MouseButton1Click:Connect(function()
			if isSelected(entry.id) then
				table.remove(selected, table.find(selected, entry.id))
			elseif #selected < MAX_SLOTS then
				table.insert(selected, entry.id)
			else
				loadoutSetStatus("Pick only 2 - deselect one first")
				return
			end
			renderLoadoutRows()
		end)
	end
end

-- Invokes the server (yields) - always call from a spawned thread.
local function refreshOwned()
	local catalog = getGachaCatalogFn:InvokeServer()
	if not catalog then
		return
	end
	ownedList = {}
	ownedById = {}
	for _, entry in ipairs(catalog.powerups) do
		if entry.tier then -- owned only
			table.insert(ownedList, { id = entry.id, displayName = entry.displayName, tier = entry.tier, rarity = entry.rarity })
			ownedById[entry.id] = { displayName = entry.displayName, tier = entry.tier }
		end
	end
	renderLoadoutRows()
	refreshActiveLabel()
end

local function buildLoadoutSection(parent)
	local activeLabel = UIStyle.MakeLabel(parent, "Active this match: none")
	activeLabel.Size = UDim2.new(1, 0, 0, 18)
	activeLabel.Position = UDim2.new(0, 0, 0, 0)

	local hintLabel = UIStyle.MakeLabel(parent, "Edits apply to your NEXT match", true)
	hintLabel.Size = UDim2.new(1, 0, 0, 16)
	hintLabel.Position = UDim2.new(0, 0, 0, 20)
	hintLabel.TextSize = 12

	local rows = makeScroller(parent, UDim2.new(0, 0, 0, 40), UDim2.new(1, 0, 1, -92))

	local saveButton = UIStyle.MakeButton(parent, "Save")
	saveButton.Size = UDim2.fromOffset(120, 28)
	saveButton.Position = UDim2.new(0, 0, 1, -48)
	saveButton.FontFace = UIStyle.HeaderFontFace

	local statusLabel = UIStyle.MakeLabel(parent, "", true)
	statusLabel.Size = UDim2.new(1, 0, 0, 16)
	statusLabel.Position = UDim2.new(0, 0, 1, -16)
	statusLabel.TextSize = 12
	statusLabel.TextColor3 = UIStyle.Colors.Accent

	loadoutRefs = { active = activeLabel, rows = rows, status = statusLabel }

	saveButton.MouseButton1Click:Connect(function()
		setLoadoutEvent:FireServer(selected)
	end)

	-- Reopen on the last thing this client saved, so the tab never looks empty
	-- just because it was closed and reopened.
	selected = table.clone(lastSaved)
	refreshActiveLabel()
	task.spawn(refreshOwned)
end

-- ============================================================
-- GACHA TAB
--
-- The reveal is PURE PRESENTATION over an instant server roll: the click fires
-- RollGacha immediately, and nothing animates until GachaResult has landed. A
-- spin that started before the outcome was known could land on the wrong prize
-- under lag, so the sequence is only ever built from a result already in hand.
-- ============================================================
-- ---- Reveal tuning ----
local SPIN_SWAPS = 16 -- name swaps before the landing (~1.5s with the ease below)
local SPIN_MIN_INTERVAL = 0.06 -- seconds between the first swaps
local SPIN_MAX_INTERVAL = 0.25 -- seconds between the last ones
local SPIN_EASE_POWER = 4 -- how sharply the swaps decelerate
local POP_SCALE = 1.12 -- landing scale pop peak
local POP_UP_TIME, POP_DOWN_TIME = 0.1, 0.15
local PULSE_IN, PULSE_OUT = 0.12, 0.18 -- background pulse toward the rarity color
local EPIC_STROKE_THICKNESS = 3 -- Epic-only stroke flare (from 1)
-- Short card, so the catalog list under it stays readable at the default size.
local CARD_Y, CARD_H = 74, 52
local IDLE_HINT = "Roll to test your luck"

-- Engine-bundled asset - no marketplace/moderation dependency, same precedent as
-- EchoCode's note. A cleaner, quieter placeholder than the ping it replaced;
-- a proper audio pass swaps these for real SFX.
local ROLL_SOUND = "rbxasset://sounds/button.wav"
-- Tick cadence matches the swap cadence so the audio tracks the visual instead
-- of lagging behind it; the volume is low enough that one per swap isn't harsh.
local TICK_EVERY = 1 -- tick on every Nth swap
local TICK_PITCH, TICK_VOLUME = 1.6, 0.12
local LANDING_VOLUME = 0.3
local RARITY_PITCH = { Common = 1.0, Rare = 1.15, Epic = 1.35 }
local EPIC_FOLLOWUP_PITCH = 1.6
local EPIC_FOLLOWUP_DELAY = 0.18

local function refreshCurrencyLabel()
	if gachaRefs then
		gachaRefs.currency.Text = "Currency: " .. tostring(localPlayer:GetAttribute("Currency") or 0)
	end
end

-- Invokes the server (yields) - always call from a spawned thread.
local function refreshCatalog()
	local catalog = getGachaCatalogFn:InvokeServer()
	if not catalog or not gachaRefs then
		return
	end

	refreshCurrencyLabel()
	gachaRefs.pity.Text = "Pity: " .. tostring(catalog.pityRollsUsed) .. "/" .. tostring(catalog.pityThreshold)
	rollCost = catalog.cost
	if not rollBusy then
		-- Mid-reveal the button reads "Rolling..." and the landing restores it.
		gachaRefs.roll.Text = "Roll (" .. tostring(catalog.cost) .. ")"
	end

	catalogById = {}
	for _, child in ipairs(gachaRefs.rows:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for i, entry in ipairs(catalog.powerups) do
		catalogById[entry.id] = entry

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -6, 0, 72)
		row.LayoutOrder = i
		row.BackgroundColor3 = UIStyle.Colors.Row
		row.BorderSizePixel = 0
		row.Parent = gachaRefs.rows

		local rowCorner = Instance.new("UICorner")
		rowCorner.CornerRadius = UDim.new(0, UIStyle.Corner)
		rowCorner.Parent = row

		local nameLabel = UIStyle.MakeLabel(row, entry.displayName .. "   " .. tostring(entry.percent) .. "%")
		nameLabel.Size = UDim2.new(1, -10, 0, 22)
		nameLabel.Position = UDim2.new(0, 5, 0, 3)
		nameLabel.FontFace = UIStyle.HeaderFontFace
		nameLabel.TextColor3 = RARITY_COLOR[entry.rarity] or UIStyle.Colors.TextPrimary

		local ownedText
		if entry.tier then
			ownedText = "Tier " .. tostring(entry.tier)
				.. " - Dupes " .. tostring(entry.duplicates) .. "/" .. tostring(entry.duplicatesNeeded)
		else
			ownedText = "Not owned"
		end
		local ownedLabel = UIStyle.MakeLabel(row, ownedText, true)
		ownedLabel.Size = UDim2.new(1, -10, 0, 18)
		ownedLabel.Position = UDim2.new(0, 5, 0, 27)

		-- Upgrade only when owned, enough duplicates banked, and below max tier.
		if entry.tier and entry.duplicates >= entry.duplicatesNeeded and entry.tier < entry.maxTier then
			local upgradeButton = UIStyle.MakeButton(row, "Upgrade")
			upgradeButton.Size = UDim2.fromOffset(130, 20)
			upgradeButton.Position = UDim2.new(0, 5, 0, 48)
			upgradeButton.MouseButton1Click:Connect(function()
				upgradePowerupEvent:FireServer(entry.id)
			end)
		end
	end
end

local function buildGachaSection(parent)
	local currencyLabel = UIStyle.MakeLabel(parent, "Currency: 0")
	currencyLabel.Size = UDim2.new(1, 0, 0, 20)
	currencyLabel.Position = UDim2.new(0, 0, 0, 0)
	currencyLabel.FontFace = UIStyle.HeaderFontFace

	local pityLabel = UIStyle.MakeLabel(parent, "Pity: 0/0", true)
	pityLabel.Size = UDim2.new(1, 0, 0, 16)
	pityLabel.Position = UDim2.new(0, 0, 0, 22)
	pityLabel.TextSize = 12

	-- One roll button - the roll decides WHICH powerup you get.
	local rollButton = UIStyle.MakeButton(parent, "Roll (50)")
	rollButton.Size = UDim2.fromOffset(150, 26)
	rollButton.Position = UDim2.new(0, 0, 0, 42)
	rollButton.FontFace = UIStyle.HeaderFontFace

	-- ---- Reveal card: where the roll visibly happens ----
	local card = UIStyle.MakePanel(
		parent,
		UDim2.new(1, 0, 0, CARD_H),
		UDim2.new(0.5, 0, 0, CARD_Y + CARD_H / 2),
		Vector2.new(0.5, 0.5) -- centered anchor so the scale pop grows both ways
	)

	local cardStroke = card:FindFirstChildOfClass("UIStroke")

	local cardScale = Instance.new("UIScale")
	cardScale.Parent = card -- destroyed with the card

	local cardLabel = UIStyle.MakeLabel(card, IDLE_HINT, true)
	cardLabel.Size = UDim2.new(1, -16, 0, 24)
	cardLabel.Position = UDim2.new(0, 8, 0, 6)
	cardLabel.FontFace = UIStyle.HeaderFontFace
	cardLabel.TextSize = 17
	cardLabel.TextTruncate = Enum.TextTruncate.AtEnd
	cardLabel.TextXAlignment = Enum.TextXAlignment.Center

	local cardBadge = UIStyle.MakeLabel(card, "", true)
	cardBadge.Size = UDim2.new(1, -16, 0, 14)
	cardBadge.Position = UDim2.new(0, 8, 0, 32)
	cardBadge.FontFace = UIStyle.HeaderFontFace
	cardBadge.TextSize = 11
	cardBadge.TextXAlignment = Enum.TextXAlignment.Center

	-- Transient Sounds parent here, so a tab rebuild's destroy sweep silences
	-- anything still ringing (Debris clears them on the normal path).
	local cardSounds = Instance.new("Frame")
	cardSounds.Name = "Sounds"
	cardSounds.Size = UDim2.fromOffset(0, 0)
	cardSounds.BackgroundTransparency = 1
	cardSounds.Visible = false
	cardSounds.Parent = card

	-- Click target over the card: pressing it skips a spin to the landing.
	local cardButton = Instance.new("TextButton")
	cardButton.Size = UDim2.new(1, 0, 1, 0)
	cardButton.BackgroundTransparency = 1
	cardButton.AutoButtonColor = false
	cardButton.Text = ""
	cardButton.ZIndex = 5
	cardButton.Parent = card

	local rows = makeScroller(parent, UDim2.new(0, 0, 0, CARD_Y + CARD_H + 6), UDim2.new(1, 0, 1, -(CARD_Y + CARD_H + 28)))

	local statusLabel = UIStyle.MakeLabel(parent, "", true)
	statusLabel.Size = UDim2.new(1, 0, 0, 16)
	statusLabel.Position = UDim2.new(0, 0, 1, -16)
	statusLabel.TextSize = 12
	statusLabel.TextColor3 = UIStyle.Colors.Accent

	gachaRefs = {
		currency = currencyLabel,
		pity = pityLabel,
		roll = rollButton,
		rows = rows,
		status = statusLabel,
		card = card,
		cardStroke = cardStroke,
		cardScale = cardScale,
		cardLabel = cardLabel,
		cardBadge = cardBadge,
		cardSounds = cardSounds,
		cardButton = cardButton,
	}

	rollButton.MouseButton1Click:Connect(function()
		if rollBusy then
			return -- a reveal is still running
		end
		rollBusy = true
		rollButton.Text = "Rolling..."
		rollButton.BackgroundTransparency = 0.5
		statusLabel.Text = ""
		cardBadge.Text = ""
		cardLabel.Text = "..."
		cardLabel.TextColor3 = UIStyle.Colors.TextDim
		-- Fire NOW: the server rolls instantly and stays the authority. The
		-- animation only starts once GachaResult tells us what was won.
		rollGachaEvent:FireServer() -- no payload; server picks the powerup
	end)

	refreshCurrencyLabel()
	task.spawn(refreshCatalog)
end

-- ============================================================
-- The reveal sequence. Everything here is guarded by rollToken: a newer roll or
-- a tab rebuild bumps it, and the running sequence stops touching the UI on its
-- next checkpoint. gachaRefs identity is checked too, so a rebuilt tab's fresh
-- card can never be driven by an older sequence.
-- ============================================================
local function playSound(refs, pitch, volume)
	-- Fire-and-forget clone so overlapping ticks don't cut each other off; these
	-- play 2D under PlayerGui, which is right for UI tones.
	local sound = Instance.new("Sound")
	sound.SoundId = ROLL_SOUND
	sound.PlaybackSpeed = pitch
	sound.Volume = volume
	sound.Parent = refs.cardSounds
	sound:Play()
	Debris:AddItem(sound, 2)
end

-- Swap interval for step i: starts fast, decelerates toward SPIN_MAX_INTERVAL.
local function spinInterval(i)
	local progress = (i - 1) / math.max(1, SPIN_SWAPS - 1)
	return SPIN_MIN_INTERVAL + (SPIN_MAX_INTERVAL - SPIN_MIN_INTERVAL) * progress ^ SPIN_EASE_POWER
end

local function playRollSequence(displayName, rarity, rollStatus)
	local refs = gachaRefs
	if not refs then
		rollBusy = false
		return
	end

	rollToken += 1
	local myToken = rollToken
	local skipped = false

	-- Alive = this exact sequence still owns this exact card.
	local function alive()
		return rollToken == myToken and gachaRefs == refs and refs.card.Parent ~= nil
	end

	local skipConn = refs.cardButton.MouseButton1Click:Connect(function()
		skipped = true
	end)

	-- Names to flicker through, drawn from the catalog we already have.
	local spinPool = {}
	for _, entry in pairs(catalogById) do
		table.insert(spinPool, entry)
	end

	task.spawn(function()
		-- ---- Spin ----
		for i = 1, SPIN_SWAPS do
			if not alive() or skipped then
				break
			end
			local pick = spinPool[math.random(1, math.max(1, #spinPool))]
			if pick then
				refs.cardLabel.Text = pick.displayName
				refs.cardLabel.TextColor3 = RARITY_COLOR[pick.rarity] or UIStyle.Colors.TextPrimary
			end
			if i % TICK_EVERY == 0 then
				playSound(refs, TICK_PITCH, TICK_VOLUME)
			end
			task.wait(spinInterval(i))
		end

		if not alive() then
			skipConn:Disconnect()
			return
		end
		skipConn:Disconnect()

		-- ---- Landing ----
		local rarityColor = RARITY_COLOR[rarity] or UIStyle.Colors.TextPrimary
		refs.cardLabel.Text = displayName
		refs.cardLabel.TextColor3 = rarityColor

		if rollStatus == "New" then
			refs.cardBadge.Text = "NEW UNLOCK!"
			refs.cardBadge.TextColor3 = UIStyle.Colors.Accent
		else
			refs.cardBadge.Text = "DUPLICATE +1"
			refs.cardBadge.TextColor3 = UIStyle.Colors.TextDim
		end

		playSound(refs, RARITY_PITCH[rarity] or 1.0, LANDING_VOLUME)

		-- Background pulse toward the rarity color and back.
		TweenService:Create(refs.card, TweenInfo.new(PULSE_IN), { BackgroundColor3 = rarityColor }):Play()
		-- Scale pop.
		TweenService:Create(refs.cardScale, TweenInfo.new(POP_UP_TIME), { Scale = POP_SCALE }):Play()
		task.wait(POP_UP_TIME)
		if not alive() then
			return
		end
		TweenService:Create(refs.cardScale, TweenInfo.new(POP_DOWN_TIME), { Scale = 1 }):Play()
		TweenService:Create(refs.card, TweenInfo.new(PULSE_OUT), { BackgroundColor3 = UIStyle.Colors.Panel }):Play()

		-- Epics get a second, bigger beat: another pulse plus a stroke flare.
		if rarity == "Epic" then
			task.wait(PULSE_OUT)
			if not alive() then
				return
			end
			TweenService:Create(refs.card, TweenInfo.new(PULSE_IN), { BackgroundColor3 = rarityColor }):Play()
			TweenService:Create(refs.cardScale, TweenInfo.new(POP_UP_TIME), { Scale = POP_SCALE + 0.06 }):Play()
			if refs.cardStroke then
				TweenService:Create(refs.cardStroke, TweenInfo.new(PULSE_IN), { Thickness = EPIC_STROKE_THICKNESS }):Play()
			end
			task.wait(EPIC_FOLLOWUP_DELAY)
			if not alive() then
				return
			end
			playSound(refs, EPIC_FOLLOWUP_PITCH, LANDING_VOLUME)
			TweenService:Create(refs.card, TweenInfo.new(PULSE_OUT), { BackgroundColor3 = UIStyle.Colors.Panel }):Play()
			TweenService:Create(refs.cardScale, TweenInfo.new(POP_DOWN_TIME), { Scale = 1 }):Play()
			if refs.cardStroke then
				TweenService:Create(refs.cardStroke, TweenInfo.new(PULSE_OUT), { Thickness = 1 }):Play()
			end
		end

		-- ---- Only now does the rest of the panel move ----
		task.wait(POP_DOWN_TIME) -- let the pop settle before anything else shifts
		if not alive() then
			return
		end

		if rollStatus == "New" then
			refs.status.Text = "New unlock - " .. displayName .. " (" .. tostring(rarity) .. ")!"
		elseif rollStatus == "Duplicate" then
			refs.status.Text = "Duplicate - " .. displayName
		else
			refs.status.Text = "Rolled " .. displayName
		end

		rollBusy = false
		refs.roll.Text = "Roll (" .. tostring(rollCost) .. ")"
		refs.roll.BackgroundTransparency = 0
		-- Catalog numbers held still through the spin; refresh them now.
		task.spawn(refreshCatalog)
	end)
end

-- ============================================================
-- SHOP SECTION - the future PURCHASE surface (event items, cosmetics bought
-- with currency). Inert: no remotes, no server calls, nothing here talks to
-- anything yet by design.
-- ============================================================
local function buildShopSection(parent)
	local title = UIStyle.MakeLabel(parent, "Shop")
	title.Size = UDim2.new(1, 0, 0, 22)
	title.Position = UDim2.new(0, 0, 0, 0)
	title.FontFace = UIStyle.HeaderFontFace
	title.TextSize = 16

	local subtitle = UIStyle.MakeLabel(parent, "Event items and cosmetics - coming soon", true)
	subtitle.Size = UDim2.new(1, 0, 0, 16)
	subtitle.Position = UDim2.new(0, 0, 0, 24)
	subtitle.TextSize = 12
end

-- ============================================================
-- COSMETICS SECTION - the future EQUIP surface for owned cosmetics. Also inert;
-- the locked slots are the shape it will take, nothing more.
-- ============================================================
local function buildCosmeticsSection(parent)
	local title = UIStyle.MakeLabel(parent, "Cosmetics")
	title.Size = UDim2.new(1, 0, 0, 18)
	title.Position = UDim2.new(0, 0, 0, 0)
	title.FontFace = UIStyle.HeaderFontFace
	title.TextSize = 14

	local subtitle = UIStyle.MakeLabel(parent, "Coming soon", true)
	subtitle.Size = UDim2.new(1, 0, 0, 14)
	subtitle.Position = UDim2.new(0, 0, 0, 18)
	subtitle.TextSize = 12

	local grid = Instance.new("Frame")
	grid.Position = UDim2.new(0, 0, 0, 36)
	grid.Size = UDim2.new(1, 0, 1, -36)
	grid.BackgroundTransparency = 1
	grid.Parent = parent

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(140, 36)
	gridLayout.CellPadding = UDim2.fromOffset(10, 8)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid

	for i = 1, 6 do
		local slot = Instance.new("Frame")
		slot.LayoutOrder = i
		slot.BackgroundColor3 = UIStyle.Colors.Row
		slot.BorderSizePixel = 0
		slot.Parent = grid

		local slotCorner = Instance.new("UICorner")
		slotCorner.CornerRadius = UDim.new(0, UIStyle.Corner)
		slotCorner.Parent = slot

		local slotLabel = UIStyle.MakeLabel(slot, "Locked", true)
		slotLabel.Size = UDim2.new(1, 0, 1, 0)
		slotLabel.TextSize = 12
		slotLabel.TextXAlignment = Enum.TextXAlignment.Center
	end
end

-- ============================================================
-- Tabs = a stack of the sections above.
-- ============================================================
local function buildStoreTab()
	buildShopSection(makeSection(UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0, 48)))
	buildGachaSection(makeSection(UDim2.new(0, 0, 0, 54), UDim2.new(1, 0, 1, -54)))
end

local function buildInventoryTab()
	buildLoadoutSection(makeSection(UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 1, -114)))
	buildCosmeticsSection(makeSection(UDim2.new(0, 0, 1, -108), UDim2.new(1, 0, 0, 108)))
end

local TAB_BUILDERS = {
	Store = buildStoreTab,
	Inventory = buildInventoryTab,
}

-- ============================================================
-- Tab switching + open/close
-- ============================================================
local function openTab(tabName)
	clearContent()
	currentTab = tabName
	-- Active tab = Accent text plus the Accent underline, the same "this is live"
	-- treatment MakeHeader gives a window title.
	for name, entry in pairs(tabButtons) do
		local active = (name == tabName)
		entry.button.TextColor3 = active and UIStyle.Colors.Accent or UIStyle.Colors.TextPrimary
		entry.underline.Visible = active
	end
	local builder = TAB_BUILDERS[tabName]
	if builder then
		builder()
	end
end

closeHub = function()
	screenGui.Enabled = false
	clearContent()
	currentTab = nil
end

-- Closed -> open on that tab. Open on a DIFFERENT tab -> switch. Open on the
-- SAME tab -> close. Used by both the hotkeys and the bottom bar.
local function requestTab(tabName)
	if not screenGui.Enabled then
		-- Always opens centered at the fixed size. Nothing else in this file ever
		-- touches the window's Position or Size.
		panel.Position = HUB_POSITION
		panel.Size = HUB_SIZE
		screenGui.Enabled = true
		openTab(tabName)
	elseif currentTab ~= tabName then
		openTab(tabName)
	else
		closeHub()
	end
end

for i, tabName in ipairs(TABS) do
	local button = UIStyle.MakeButton(tabRow, tabName)
	button.Size = UDim2.fromOffset(130, 28)
	button.LayoutOrder = i
	button.FontFace = UIStyle.HeaderFontFace
	button.MouseButton1Click:Connect(function()
		-- In-window tabs only ever switch; the X is what closes.
		if currentTab ~= tabName then
			openTab(tabName)
		end
	end)

	local underline = Instance.new("Frame")
	underline.AnchorPoint = Vector2.new(0.5, 1)
	underline.Position = UDim2.new(0.5, 0, 1, -2)
	underline.Size = UDim2.new(1, -12, 0, 2)
	underline.BackgroundColor3 = UIStyle.Colors.Accent
	underline.BorderSizePixel = 0
	underline.Visible = false
	underline.Parent = button

	tabButtons[tabName] = { button = button, underline = underline }
end

hubOpenEvent.Event:Connect(requestTab)

-- ============================================================
-- Remote listeners. These run whether or not their tab is built - the state is
-- tracked always, and the UI updates only if it currently exists.
-- ============================================================
loadoutAppliedEvent.OnClientEvent:Connect(function(activeIds)
	activeLoadout = activeIds or {}
	refreshActiveLabel()
end)

loadoutResultEvent.OnClientEvent:Connect(function(success, reason)
	if success then
		lastSaved = table.clone(selected)
		loadoutSetStatus("Saved - applies when the next match starts")
	else
		loadoutSetStatus(tostring(reason))
	end
end)

-- The outcome is already decided server-side by the time this arrives; the
-- reveal is built FROM it, never ahead of it.
gachaResultEvent.OnClientEvent:Connect(function(success, resultOrError, powerupId, rollStatus)
	if not gachaRefs then
		rollBusy = false
		return
	end

	if not success then
		-- No animation on a rejected roll: say why and hand the button back.
		if resultOrError == "InsufficientCurrency" then
			gachaRefs.status.Text = "Not enough currency"
		else
			gachaRefs.status.Text = tostring(resultOrError)
		end
		gachaRefs.cardLabel.Text = IDLE_HINT
		gachaRefs.cardLabel.TextColor3 = UIStyle.Colors.TextDim
		gachaRefs.cardBadge.Text = ""
		rollBusy = false
		gachaRefs.roll.Text = "Roll (" .. tostring(rollCost) .. ")"
		gachaRefs.roll.BackgroundTransparency = 0
		-- Re-run so tier/duplicate progress + pity reflect the attempt.
		task.spawn(refreshCatalog)
		return
	end

	local entry = catalogById[powerupId]
	local displayName = entry and entry.displayName or tostring(powerupId)
	local rarity = entry and entry.rarity or "Common"
	-- The status line and the catalog refresh are deferred into the landing, so
	-- nothing on the panel spoils the spin or moves under it.
	playRollSequence(displayName, rarity, rollStatus)
end)

upgradeResultEvent.OnClientEvent:Connect(function(powerupId, success, tierOrReason)
	if gachaRefs then
		local entry = catalogById[powerupId]
		local displayName = entry and entry.displayName or tostring(powerupId)
		if success then
			gachaRefs.status.Text = displayName .. " upgraded to Tier " .. tostring(tierOrReason) .. "!"
		elseif tierOrReason == "NotEnoughDuplicates" then
			gachaRefs.status.Text = "Not enough duplicates"
		elseif tierOrReason == "MaxTier" then
			gachaRefs.status.Text = "Already at max tier"
		elseif tierOrReason == "NotOwned" then
			gachaRefs.status.Text = "You don't own that"
		else
			gachaRefs.status.Text = tostring(tierOrReason)
		end
	end

	task.spawn(refreshCatalog)
end)

localPlayer:GetAttributeChangedSignal("Currency"):Connect(refreshCurrencyLabel)

-- A meeting owns the screen. Reopens by key or bar button only.
meetingStartedEvent.OnClientEvent:Connect(function()
	if screenGui.Enabled then
		closeHub()
	end
end)

-- ============================================================
-- Hotkeys
-- ============================================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.G then
		requestTab("Store")
	elseif input.KeyCode == Enum.KeyCode.L then
		requestTab("Inventory")
	end
end)
