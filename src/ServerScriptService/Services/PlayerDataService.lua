--[[
	PlayerDataService.lua
	The DataStore-backed home for persistent player data. Promoted ahead of the
	Forge per docs/DESIGN.md sections 8 & 11 - "a forge economy that resets per
	server is not an economy."

	This module owns LOADING, SAVING and the in-memory session table only. It does
	NOT interpret the data: currency, charm ownership and gacha pity are all
	read/written THROUGH their owning services (GachaService, PowerupOwnershipService,
	the Bootstrap currency mirror), which call Get/MarkDirty/IsLoaded here. Those
	services hydrate their own caches from the load via the OnLoaded hook.

	DATA-LOSS GUARD: if a player's data fails to load after every retry, we serve
	throwaway defaults but mark the session UNSAVEABLE, so we can NEVER later
	overwrite whatever real data exists in the store with those defaults.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local PlayerDataService = {}

local STORE_NAME = "SuspectPlayerData_v1"
local store = DataStoreService:GetDataStore(STORE_NAME)

local SCHEMA_VERSION = 1
local STARTING_CURRENCY = 500 -- matches the old Bootstrap attribute stub
local MAX_LOAD_RETRIES = 3
local AUTOSAVE_INTERVAL = 120 -- seconds; only dirty, saveable sessions are written
local STUDIO_CLOSE_WAIT = 3 -- BindToClose grace so async saves can land in Studio

-- player -> { data = <schema>, loaded = bool, saveable = bool, dirty = bool }
local sessions = {}

-- Fired with (player) once a load resolves (success OR default-on-failure), so
-- owning services can hydrate their caches. Same one-directional hook pattern the
-- rest of the codebase uses - PlayerDataService never requires those services.
local onLoadedCallbacks = {}
function PlayerDataService.OnLoaded(callback)
	table.insert(onLoadedCallbacks, callback)
end

local function keyFor(player)
	return "Player_" .. player.UserId
end

local function defaultData()
	return {
		version = SCHEMA_VERSION,
		currency = STARTING_CURRENCY,
		ownership = {}, -- [charmId] = { tier, dupes }
		pity = 0,
		memoria = 0, -- Phase 3 scaffold (ghost economy): stored, never read yet
	}
end

-- Fill any field a stored record predates, so readers never hit nil.
local function normalize(raw)
	if type(raw) ~= "table" then
		return defaultData()
	end
	raw.version = raw.version or SCHEMA_VERSION
	if raw.currency == nil then
		raw.currency = STARTING_CURRENCY
	end
	if type(raw.ownership) ~= "table" then
		raw.ownership = {}
	end
	if raw.pity == nil then
		raw.pity = 0
	end
	if raw.memoria == nil then
		raw.memoria = 0
	end
	return raw
end

-- ============================================================
-- Public API. Everything else in the game goes through the owning services,
-- which in turn call these three.
-- ============================================================
function PlayerDataService.Get(player)
	local session = sessions[player]
	return session and session.data or nil
end

function PlayerDataService.IsLoaded(player)
	local session = sessions[player]
	return session ~= nil and session.loaded == true
end

function PlayerDataService.MarkDirty(player)
	local session = sessions[player]
	-- No point marking an unsaveable session dirty - it will never be written.
	if session and session.saveable then
		session.dirty = true
	end
end

-- ============================================================
-- Load
-- ============================================================
local function loadWithRetries(player)
	local key = keyFor(player)
	for attempt = 1, MAX_LOAD_RETRIES do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			return true, result
		end
		warn(("[PlayerDataService] load attempt %d/%d failed for %s: %s")
			:format(attempt, MAX_LOAD_RETRIES, player.Name, tostring(result)))
		if attempt < MAX_LOAD_RETRIES then
			task.wait(attempt) -- linear backoff: 1s, 2s
		end
	end
	return false, nil
end

local function onPlayerAdded(player)
	local ok, raw = loadWithRetries(player)

	-- The player may have left during the async load; don't create a session.
	if player.Parent ~= Players then
		return
	end

	local session
	if ok then
		session = { data = normalize(raw), loaded = true, saveable = true, dirty = false }
	else
		-- DATA-LOSS GUARD: every retry failed. Serve defaults so the player can
		-- still play, but keep the session UNSAVEABLE so a later save can never
		-- clobber their real (unread) data in the store.
		warn(("[PlayerDataService] LOAD FAILED for %s after %d attempts - serving DEFAULTS and marking the session UNSAVEABLE (nothing will persist this session)."):format(player.Name, MAX_LOAD_RETRIES))
		session = { data = defaultData(), loaded = true, saveable = false, dirty = false }
	end
	sessions[player] = session

	for _, callback in ipairs(onLoadedCallbacks) do
		local cbOk, err = pcall(callback, player)
		if not cbOk then
			warn("[PlayerDataService] OnLoaded callback errored:", err)
		end
	end
end

-- ============================================================
-- Save
-- ============================================================
-- Writes only dirty, SAVEABLE sessions. Safe to call on anyone at any time.
local function saveIfNeeded(player)
	local session = sessions[player]
	if not session or not session.saveable or not session.dirty then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync(keyFor(player), session.data)
	end)
	if ok then
		session.dirty = false
	else
		warn("[PlayerDataService] save failed for", player.Name, ":", tostring(err))
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
-- Cover any player already present when this module initializes.
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	saveIfNeeded(player)
	sessions[player] = nil
end)

-- Autosave: flush every dirty, saveable session on a fixed cadence.
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for player in pairs(sessions) do
			saveIfNeeded(player)
		end
	end
end)

-- Flush everyone on shutdown. BindToClose blocks the server dying until it
-- returns; the trailing wait gives the spawned async saves time to land, which
-- matters most under Studio's near-instant teardown.
game:BindToClose(function()
	for player in pairs(sessions) do
		task.spawn(saveIfNeeded, player)
	end
	task.wait(RunService:IsStudio() and STUDIO_CLOSE_WAIT or 1)
end)

return PlayerDataService
