--[[
	SabotageService.lua
	Server-authoritative sabotage: what an impostor may trigger, the shared
	cooldown, the critical (boiler) countdown, and the fix sessions crew players
	open at the tagged fix stations.

	Fix minigames deliberately reuse the TASK pipeline (TaskOpen -> minigame ->
	TaskFinished/TaskCancel). A fix IS a task as far as the client is concerned;
	the only difference is who owns the session server-side. Bootstrap routes each
	incoming TaskFinished/TaskCancel by session owner - this module first, then
	TaskManager - so the client never has to know which kind of window it opened.

	IMPORTANT (cycle-safety): NOTHING requires SabotageService except Bootstrap
	and the handler scripts (SabotageStationHandler, EmergencyButtonHandler,
	BodyReportHandler). This module requires MatchService, MeetingSystem and
	LightsSystem, so any of those requiring it back would create a cycle. The
	reverse channels are the hooks registered at the bottom of this file
	(OnMeetingStart / OnMatchStart) plus RegisterOnSabotageChanged, which the
	station handler uses instead of being reached into from here.

	SCOPE (accepted, not a gap): two sabotages exist because the FRAMEWORK is the
	deliverable - doors/comms arrive as per-map data later. Triggering is
	map-wide by design (no console to walk to yet), lights-out persists until
	fixed with no failsafe timer, and an impostor fixing their own sabotage is
	legal and intended (cover plays).
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local TaskDefs = require(ReplicatedStorage.Modules.TaskDefs)
local DebugFlags = require(ServerScriptService.Services.DebugFlags)
local RoleManager = require(ServerScriptService.Services.RoleManager)
local MatchService = require(ServerScriptService.Services.MatchService)
local MeetingSystem = require(ServerScriptService.Services.MeetingSystem)
local LightsSystem = require(ServerScriptService.Services.LightsSystem)

local SabotageService = {}

-- ============================================================
-- TUNING
-- ============================================================
local SABOTAGE_COOLDOWN = 30 -- seconds after a sabotage resolves before the next
local MATCH_START_DELAY = 20 -- opening grace period; no sabotage this early
local BOILER_TIME = 45 -- seconds the crew has to fix the boiler before losing
-- How close (studs) a player's HumanoidRootPart must be to the fix station to
-- finish - same anti-teleport / anti-remote-spoof floor as TaskManager's.
local FIX_RANGE = 12

-- The role string that may sabotage. DebugFlags.ALL_IMPOSTORS needs no
-- special-casing here: it makes everyone's ASSIGNED role Impostor, so every
-- player passes this gate naturally through RoleManager.
local IMPOSTOR_ROLE = "Impostor"

-- ============================================================
-- Definitions. Station keys are the RESERVED fix taskIds (the FixId attribute a
-- tagged part carries); values are the TaskDefs type whose minigame the fix
-- opens. A sabotage resolves when EVERY station in its table is fixed.
-- ============================================================
local Sabotages = {
	Lights = {
		critical = false,
		stations = {
			["Sabotage:Lights"] = "FixSwitches",
		},
	},
	Boiler = {
		critical = true,
		timer = BOILER_TIME,
		stations = {
			["Sabotage:Boiler1"] = "FixValve",
			["Sabotage:Boiler2"] = "FixValve",
		},
	},
}

-- Reverse index built once: fix taskId -> its sabotage type.
local stationSabotage = {}
for sabotageType, def in pairs(Sabotages) do
	for taskId in pairs(def.stations) do
		stationSabotage[taskId] = sabotageType
	end
end

-- ============================================================
-- State
-- ============================================================
-- nil, or { type = string, endsAt = number|nil (critical only), stationsFixed = { [taskId] = true } }
local active = nil
local cooldownReadyAt = 0
-- player -> { taskId = string, startClock = number }. One live fix session per
-- player; starting a new one silently replaces any previous (mirrors TaskManager).
local fixSessions = {}
-- taskId -> the station Part, registered by SabotageStationHandler.
local stationParts = {}
-- Identity token for the live critical countdown (same pattern as every timed
-- loop in this codebase): a running loop only acts while it is STILL the token
-- held here, so a stale loop from a resolved sabotage can never end a match.
local timerToken = nil

if DebugFlags.ALL_IMPOSTORS then
	print("[SabotageService] ALL_IMPOSTORS is on - every player's assigned role passes the impostor sabotage gate.")
end

-- ============================================================
-- Change hooks + broadcast
-- ============================================================
-- Callbacks fired whenever sabotage state changes (activate, a station fixed,
-- resolve). Lets SabotageStationHandler drive its prompts without this module
-- knowing anything about parts or prompts - keeps the dependency
-- one-directional and cycle-free.
local sabotageChangedCallbacks = {}

function SabotageService.RegisterOnSabotageChanged(callback)
	table.insert(sabotageChangedCallbacks, callback)
end

local function countKeys(t)
	local count = 0
	for _ in pairs(t) do
		count += 1
	end
	return count
end

-- The SabotageStatus payload for the CURRENT state. Broadcasting it to everyone
-- leaks nothing: an active sabotage is globally obvious (lights out, alarms).
local function statusPayload()
	if not active then
		return { type = nil, active = false, critical = false, timeLeft = nil, fixedCount = 0, totalStations = 0 }
	end

	local def = Sabotages[active.type]
	return {
		type = active.type,
		active = true,
		critical = def.critical,
		timeLeft = active.endsAt and math.max(0, math.ceil(active.endsAt - os.clock())) or nil,
		fixedCount = countKeys(active.stationsFixed),
		totalStations = countKeys(def.stations),
	}
end

local function broadcast()
	Remotes.Get(Remotes.Names.SabotageStatus):FireAllClients(statusPayload())
end

local function fireChanged(sabotageType, isActive)
	for _, callback in ipairs(sabotageChangedCallbacks) do
		callback(sabotageType, isActive)
	end
end

-- ============================================================
-- Stations
-- ============================================================
-- Called by SabotageStationHandler for each tagged part. Returns the TaskDefs
-- fix type this station opens, or nil if the taskId isn't a known fix station.
function SabotageService.RegisterFixStation(taskId, part, sabotageType)
	local owner = stationSabotage[taskId]
	if owner == nil then
		warn("[SabotageService] Unknown fix station id '" .. tostring(taskId) .. "' - not one of the reserved station ids; that part will do nothing.")
		return nil
	end
	if sabotageType ~= nil and owner ~= sabotageType then
		warn("[SabotageService] Fix station '" .. taskId .. "' belongs to sabotage '" .. owner .. "', not '" .. tostring(sabotageType) .. "' - fix the part's attributes; it will do nothing.")
		return nil
	end

	stationParts[taskId] = part
	return Sabotages[owner].stations[taskId]
end

-- True iff a sabotage is active and this station has already been fixed. Used by
-- the station handler to keep a fixed station's prompt off for the rest of the
-- sabotage.
function SabotageService.IsStationFixed(taskId)
	return active ~= nil and active.stationsFixed[taskId] == true
end

-- ============================================================
-- Accessors
-- ============================================================
function SabotageService.IsActive()
	return active ~= nil
end

function SabotageService.IsCriticalActive()
	return active ~= nil and Sabotages[active.type].critical == true
end

-- ============================================================
-- Clear / resolve
-- ============================================================
-- Wipes all live sabotage state and tells everyone. Does NOT arm the cooldown -
-- callers decide which cooldown applies (Resolve arms the normal one, match
-- start arms the opening delay instead).
local function clearActive(reason)
	local wasType = active and active.type or nil

	if wasType == "Lights" then
		LightsSystem.SetLightsOut(false)
	end

	timerToken = nil -- cancels any live countdown loop (identity-token guard)
	active = nil
	fixSessions = {} -- every open fix window dies with the sabotage

	if wasType then
		print("[SabotageService]", wasType, "sabotage cleared -", reason)
		fireChanged(wasType, false)
	end
	broadcast()
end

-- reason: "Fixed" | "MeetingStarted" | ...
function SabotageService.Resolve(reason)
	clearActive(reason)
	cooldownReadyAt = os.clock() + SABOTAGE_COOLDOWN
end

-- ============================================================
-- Trigger
-- ============================================================
local function startCriticalTimer()
	local token = {}
	timerToken = token

	task.spawn(function()
		-- Identity-token guard: this loop only acts while it is STILL the live
		-- timer. Resolve/match-start nil the token, so a stale loop from an
		-- already-fixed boiler can never broadcast or end a match.
		while timerToken == token do
			task.wait(1)
			if timerToken ~= token or active == nil then
				return
			end

			if os.clock() >= active.endsAt then
				timerToken = nil
				broadcast() -- final tick: timeLeft reads 0
				-- Non-count win condition, so it can't go through
				-- EvaluateWinCondition - the alive/task counts didn't change.
				MatchService.ForceEnd("ImpostorWin")
				return
			end

			broadcast()
		end
	end)
end

-- Returns true, or (false, reason). Sabotage can be called from anywhere on the
-- map by design - there is no console to walk to yet.
function SabotageService.Trigger(player, sabotageType)
	local def = Sabotages[sabotageType]
	if def == nil then
		return false, "UnknownSabotage"
	end
	if MatchService.GetState() ~= "InProgress" then
		return false, "NoMatch"
	end
	if MeetingSystem.IsMeetingActive() then
		return false, "MeetingActive"
	end
	if not RoleManager.IsAlive(player) then
		return false, "Dead"
	end
	if RoleManager.GetRole(player) ~= IMPOSTOR_ROLE then
		return false, "NotImpostor"
	end
	if active ~= nil then
		return false, "AlreadyActive"
	end
	if os.clock() < cooldownReadyAt then
		return false, "Cooldown"
	end

	active = { type = sabotageType, stationsFixed = {} }

	if sabotageType == "Lights" then
		LightsSystem.SetLightsOut(true)
	end
	-- Countdown is driven by the definition, not by the sabotage's name, so a
	-- future critical sabotage only has to declare critical + timer.
	if def.critical then
		active.endsAt = os.clock() + def.timer
		startCriticalTimer()
	end

	print("[SabotageService]", player.Name, "triggered", sabotageType)
	fireChanged(sabotageType, true)
	broadcast()

	return true
end

-- ============================================================
-- Fix sessions. Same shape as TaskManager's session API so Bootstrap can route
-- the shared client pipeline to whichever module owns the player's session.
-- ============================================================
-- Open a fix session. Impostors may fix by design (cover plays) - the only
-- life gate is being alive.
function SabotageService.StartFix(player, taskId)
	if active == nil or stationSabotage[taskId] ~= active.type then
		return false, "NotActive"
	end
	if active.stationsFixed[taskId] then
		return false, "AlreadyFixed"
	end
	if not RoleManager.IsAlive(player) then
		return false, "Dead"
	end

	fixSessions[player] = { taskId = taskId, startClock = os.clock() }
	return true
end

-- True iff this player has a live fix session AND it is for this exact taskId.
function SabotageService.HasFixSession(player, taskId)
	local session = fixSessions[player]
	return session ~= nil and session.taskId == taskId
end

-- Cancel an OPEN attempt: clears this player's session only if it exists and
-- matches taskId (otherwise a no-op). Never un-fixes a station.
function SabotageService.CancelFix(player, taskId)
	local session = fixSessions[player]
	if session and session.taskId == taskId then
		fixSessions[player] = nil
	end
end

-- Validate and finish an open fix session. On success marks the station fixed
-- and, once every station of the active sabotage is done, resolves it.
function SabotageService.TryFinishFix(player, taskId)
	local session = fixSessions[player]
	if not session or session.taskId ~= taskId then
		return false, "NoSession"
	end
	if active == nil or stationSabotage[taskId] ~= active.type then
		return false, "NotActive"
	end
	if active.stationsFixed[taskId] then
		return false, "AlreadyFixed"
	end

	local fixType = Sabotages[active.type].stations[taskId]
	if os.clock() - session.startClock < TaskDefs.Get(fixType).minDuration then
		return false, "TooFast"
	end

	local part = stationParts[taskId]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not part or not root or (root.Position - part.Position).Magnitude > FIX_RANGE then
		return false, "TooFar"
	end

	active.stationsFixed[taskId] = true
	fixSessions[player] = nil

	-- Tell the handler (prompt off for this station) and the clients before the
	-- all-fixed check, so a multi-station sabotage shows partial progress.
	fireChanged(active.type, true)
	broadcast()

	local allFixed = true
	for stationId in pairs(Sabotages[active.type].stations) do
		if not active.stationsFixed[stationId] then
			allFixed = false
			break
		end
	end
	if allFixed then
		SabotageService.Resolve("Fixed")
	end

	return true
end

-- ============================================================
-- Reverse-channel hooks (see the cycle-safety note at the top)
-- ============================================================
-- A meeting supersedes a sabotage: everyone is frozen at the table, so nobody
-- could reach a fix station anyway.
MeetingSystem.OnMeetingStart(function()
	if active ~= nil then
		SabotageService.Resolve("MeetingStarted")
	end
end)

-- Full reset for a new round. Deliberately does NOT arm the normal post-fix
-- cooldown - the opening grace period replaces it.
MatchService.OnMatchStart(function()
	clearActive("MatchStart")
	cooldownReadyAt = os.clock() + MATCH_START_DELAY
end)

Players.PlayerRemoving:Connect(function(player)
	fixSessions[player] = nil
end)

return SabotageService
