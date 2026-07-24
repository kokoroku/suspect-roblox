--[[
	EchoCode.lua
	The "Play Back the Piano Refrain" (EchoCode) minigame. A Simon-style memory
	game: watch the piano keys flash a melody, then play it back. Clear ROUNDS
	rounds of increasing length to finish. Missing a note costs time, not
	progress - you replay the same round from its Listen phase, forever, until
	you get it. That time cost is what makes this a Long task.

	Implements the standard minigame contract (see Placeholder.lua):
	    Build(contentFrame, config, onComplete) -> cleanup
	  - builds its whole UI inside contentFrame,
	  - calls onComplete() EXACTLY once when the final round is cleared,
	  - returns a cleanup that fully undoes everything and is safe to call at ANY
	    moment, including mid-playback (the runner calls it on walk-away,
	    meetings, death and respawn).

	Accepted current behavior: visual-only piano (no audio yet - the sound pass
	comes with UI polish), one shared HIGHLIGHT color for all keys, no persistence
	(reopening restarts at round 1 with a fresh melody; the server clears the
	session anyway), no mobile-specific sizing, Estate skin only.
]]

local Debris = game:GetService("Debris")

local EchoCode = {}

-- ============================================================
-- TUNING - the knobs to tweak later.
-- ============================================================
local KEY_COUNT = 4 -- number of piano keys
local ROUNDS = 3 -- rounds to clear to finish
local START_LENGTH = 3 -- round 1 sequence length (rounds run 3, 4, 5)
local EXTEND_SEQUENCE = true -- true: append one note to the same melody each round (classic Simon); false: fresh random sequence per round

local NOTE_ON = 0.35 -- seconds a note stays highlighted during Listen
local NOTE_GAP = 0.15 -- gap between notes during Listen (also splits repeats into two flashes)
local ROUND_PAUSE = 0.6 -- pause after clearing a round before the next Listen
local WRONG_FLASH = 0.45 -- seconds all keys stay red after a wrong press

local KEY_COLOR = Color3.fromRGB(240, 240, 235) -- resting key
local HIGHLIGHT = Color3.fromRGB(235, 200, 80) -- flashing / correct note
local WRONG_COLOR = Color3.fromRGB(220, 70, 70) -- wrong press
local CLEAR_COLOR = Color3.fromRGB(100, 200, 110) -- round / task cleared

local NOTE_SOUND = "rbxasset://sounds/electronicpingshort.wav" -- engine-bundled asset - no marketplace/moderation dependency; the polish pass swaps this for real piano samples
local VOLUME = 0.5
local PITCHES = { 1.0, 1.26, 1.5, 2.0 } -- PlaybackSpeed per key index - root/major third/fifth/octave; must have at least KEY_COUNT entries
local WRONG_PITCH = 0.45

-- Not core knobs:
local CORRECT_FLASH = 0.15 -- how long a correctly-pressed key flashes before reverting
local KEY_TEXT = Color3.fromRGB(40, 40, 40) -- dark label on the light keys
local PIP_DARK = Color3.fromRGB(55, 55, 60) -- an uncleared round pip
local KEY_W, KEY_H, KEY_PAD = 70, 130, 12 -- key size and spacing

function EchoCode.Build(contentFrame, _config, onComplete)
	local conns = {} -- EVERY connection made anywhere goes in here
	local instances = {} -- every top-level instance created inside contentFrame

	local function track(instance)
		table.insert(instances, instance)
		return instance
	end

	-- ============================================================
	-- Cancellation core: a single monotonically increasing session id.
	-- Every phase (playback, input, wrong-flash, round transition) bumps it and
	-- captures the new value; every task.wait loop and task.delay callback checks
	-- its captured value against `session` BEFORE touching anything and silently
	-- aborts on mismatch. cleanup() bumps it too, so no timed callback can ever
	-- reach a destroyed instance. The session check ALWAYS comes first.
	-- ============================================================
	local session = 0
	local inputSession = -1 -- session value of the live input phase (-1 = none yet)

	-- ---- Status label (across the top) ----
	local status = track(Instance.new("TextLabel"))
	status.Size = UDim2.new(1, 0, 0, 24)
	status.BackgroundTransparency = 1
	status.TextColor3 = Color3.new(1, 1, 1)
	status.TextScaled = true
	status.Font = Enum.Font.Gotham
	status.Text = ""
	status.Parent = contentFrame

	-- ---- Round pips (top-right, dark until their round is cleared) ----
	local pipHolder = track(Instance.new("Frame"))
	pipHolder.AnchorPoint = Vector2.new(1, 0)
	pipHolder.Position = UDim2.new(1, -4, 0, 6)
	pipHolder.Size = UDim2.fromOffset(ROUNDS * 12 + (ROUNDS - 1) * 4, 12)
	pipHolder.BackgroundTransparency = 1
	pipHolder.ZIndex = 2
	pipHolder.Parent = contentFrame

	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.Padding = UDim.new(0, 4)
	pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	pipLayout.Parent = pipHolder -- destroyed with pipHolder

	local pips = {}
	for r = 1, ROUNDS do
		local pip = Instance.new("Frame")
		pip.Size = UDim2.fromOffset(12, 12)
		pip.BackgroundColor3 = PIP_DARK
		pip.BorderSizePixel = 0
		pip.LayoutOrder = r
		pip.ZIndex = 2
		pip.Parent = pipHolder -- destroyed with pipHolder
		pips[r] = pip
	end

	-- ---- Keys (centered row of piano keys) ----
	local keyRow = track(Instance.new("Frame"))
	keyRow.AnchorPoint = Vector2.new(0.5, 0.5)
	keyRow.Position = UDim2.new(0.5, 0, 0.5, 12) -- a touch below center, clear of the status label
	keyRow.Size = UDim2.fromOffset(KEY_COUNT * KEY_W + (KEY_COUNT - 1) * KEY_PAD, KEY_H)
	keyRow.BackgroundTransparency = 1
	keyRow.Parent = contentFrame

	local keyLayout = Instance.new("UIListLayout")
	keyLayout.FillDirection = Enum.FillDirection.Horizontal
	keyLayout.Padding = UDim.new(0, KEY_PAD)
	keyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	keyLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	keyLayout.SortOrder = Enum.SortOrder.LayoutOrder
	keyLayout.Parent = keyRow -- destroyed with keyRow

	local keys = {}
	for i = 1, KEY_COUNT do
		local key = Instance.new("TextButton")
		key.Size = UDim2.fromOffset(KEY_W, KEY_H)
		key.BackgroundColor3 = KEY_COLOR
		key.AutoButtonColor = false -- our color changes must read cleanly
		key.BorderSizePixel = 0
		key.LayoutOrder = i
		key.Text = tostring(i)
		key.Font = Enum.Font.GothamBold
		key.TextColor3 = KEY_TEXT
		key.TextScaled = true
		key.Parent = keyRow -- destroyed with keyRow

		local corner = Instance.new("UICorner")
		corner.Parent = key -- destroyed with the key

		keys[i] = key
	end

	-- ---- Sound container (transient notes parent here, so the existing cleanup
	-- destroy-everything sweep silences anything still ringing on teardown) ----
	local soundContainer = track(Instance.new("Frame"))
	soundContainer.Name = "Sounds"
	soundContainer.Size = UDim2.fromOffset(0, 0)
	soundContainer.BackgroundTransparency = 1
	soundContainer.Visible = false
	soundContainer.Parent = contentFrame

	-- ---- Helpers ----
	local function playNote(pitch)
		-- Fire-and-forget clone so fast consecutive notes overlap instead of
		-- cutting each other off. Under PlayerGui these play 2D/non-spatial,
		-- which is exactly right for UI tones.
		local sound = Instance.new("Sound")
		sound.SoundId = NOTE_SOUND
		sound.PlaybackSpeed = pitch
		sound.Volume = VOLUME
		sound.Parent = soundContainer
		sound:Play()
		Debris:AddItem(sound, 2)
	end

	local function randKey()
		return math.random(1, KEY_COUNT) -- back-to-back repeats allowed; the gap splits them visually
	end

	local function freshSequence(length)
		local seq = {}
		for i = 1, length do
			seq[i] = randKey()
		end
		return seq
	end

	local function setAllKeys(color, transparency)
		for _, key in ipairs(keys) do
			key.BackgroundColor3 = color
			key.BackgroundTransparency = transparency
		end
	end

	-- ============================================================
	-- Game state + flow
	-- ============================================================
	local currentRound = 1
	local sequence = freshSequence(START_LENGTH) -- round 1 melody
	local inputIndex = 0
	local onCompleteFired = false

	-- Forward declarations (the phases call each other).
	local startListen, startInput, onRoundComplete, onWrong

	-- Listen phase: play the current melody, then hand off to input.
	startListen = function()
		session += 1
		local mySession = session
		inputSession = -1 -- presses ignored during playback
		inputIndex = 0
		status.Text = "Listen..."
		setAllKeys(KEY_COLOR, 0.15) -- dimmed while the game plays

		task.spawn(function()
			for _, note in ipairs(sequence) do
				if session ~= mySession then
					return
				end
				keys[note].BackgroundColor3 = HIGHLIGHT
				playNote(PITCHES[note] or 1)
				task.wait(NOTE_ON)
				if session ~= mySession then
					return
				end
				keys[note].BackgroundColor3 = KEY_COLOR
				task.wait(NOTE_GAP)
			end
			if session ~= mySession then
				return
			end
			startInput()
		end)
	end

	-- Input phase: accept presses via Activated (mouse + touch).
	startInput = function()
		session += 1
		inputSession = session
		inputIndex = 0
		status.Text = "Your turn (0/" .. #sequence .. ")"
		setAllKeys(KEY_COLOR, 0) -- full opacity, accepting presses
	end

	-- Round cleared: fill the pip, flash, pause, then advance (or finish).
	onRoundComplete = function()
		session += 1
		local mySession = session
		inputSession = -1
		pips[currentRound].BackgroundColor3 = CLEAR_COLOR
		setAllKeys(CLEAR_COLOR, 0)

		if currentRound >= ROUNDS then
			-- Final round done: onComplete exactly once.
			if not onCompleteFired then
				onCompleteFired = true
				status.Text = "Complete!"
				playNote(PITCHES[#PITCHES]) -- final flourish; between-round clears stay silent
				onComplete()
			end
			return
		end

		task.spawn(function()
			task.wait(ROUND_PAUSE)
			if session ~= mySession then
				return
			end
			currentRound += 1
			if EXTEND_SEQUENCE then
				table.insert(sequence, randKey()) -- append one note to the same melody
			else
				sequence = freshSequence(START_LENGTH + currentRound - 1) -- fresh melody at the new length
			end
			startListen()
		end)
	end

	-- Wrong press: flash red, then replay the SAME round from Listen. A miss never
	-- rerolls the notes and cleared pips never un-fill.
	onWrong = function()
		session += 1
		local mySession = session
		inputSession = -1
		status.Text = "Wrong - listen again"
		setAllKeys(WRONG_COLOR, 0)
		playNote(WRONG_PITCH)

		task.spawn(function()
			task.wait(WRONG_FLASH)
			if session ~= mySession then
				return
			end
			startListen()
		end)
	end

	-- ---- Key input (connected once; the session guard gates it by phase) ----
	for index, key in ipairs(keys) do
		table.insert(conns, key.Activated:Connect(function()
			-- Only the live input phase accepts presses; listen/flash/transition
			-- have already bumped session past inputSession, so they're ignored.
			if session ~= inputSession then
				return
			end

			if index == sequence[inputIndex + 1] then
				inputIndex += 1
				-- Flash the correct key, revert on a session-guarded delay.
				key.BackgroundColor3 = HIGHLIGHT
				playNote(PITCHES[index] or 1) -- player audibly plays the melody back
				local flashSession = session
				task.delay(CORRECT_FLASH, function()
					if session ~= flashSession then
						return
					end
					key.BackgroundColor3 = KEY_COLOR
				end)

				if inputIndex >= #sequence then
					onRoundComplete()
				else
					status.Text = "Your turn (" .. inputIndex .. "/" .. #sequence .. ")"
				end
			else
				onWrong()
			end
		end))
	end

	-- Kick off round 1.
	startListen()

	-- ============================================================
	-- Cleanup - safe at any moment, including mid-playback. Bump session FIRST so
	-- any in-flight timed callback sees the mismatch and aborts before it can
	-- touch an instance we're about to destroy.
	-- ============================================================
	return function()
		session += 1
		for _, connection in ipairs(conns) do
			connection:Disconnect()
		end
		for _, instance in ipairs(instances) do
			instance:Destroy()
		end
	end
end

return EchoCode
