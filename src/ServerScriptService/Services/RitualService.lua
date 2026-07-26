--[[
	RitualService.lua
	The Banishment made real (docs/DESIGN.md sections 3, 5 and 9). Owns:
	  - BRAZIERS: tagged world parts, lit one per completed task. The task bar made
	    physical and visible to everyone, Vessel included.
	  - THRESHOLD: how many lit braziers arm the ritual, computed once per match.
	  - THE CONVERGENCE: the endgame channel. Living crew must physically hold the
	    circle for a sustained duration; completing it IS the crew win.
	  - DESECRATE: the Vessel snuffing the most recently lit brazier (SabotageService
	    owns the trigger; the world effect lives here).
	  - THE ENTITY'S RAGE: as braziers light, Vessel cooldowns ease and the manor
	    dims. No doom clock - success breeds danger instead.

	IMPORTANT (cycle-safety): NOTHING requires RitualService except Bootstrap and
	SabotageService. This module requires MatchService, TaskManager, KillSystem and
	LightsSystem, so any of those requiring it back would create a cycle. Two reverse
	channels keep it one-directional:
	  - The crew-objective seam is INJECTED by Bootstrap (MatchService never requires
	    this module - see MatchService's seam comment).
	  - The Rage multiplier reaches SabotageService through OnRageChanged, which
	    SabotageService registers itself; this module never requires it back.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local GameConstants = require(ReplicatedStorage.Modules.GameConstants)
local RoleManager = require(ServerScriptService.Services.RoleManager)
local MatchService = require(ServerScriptService.Services.MatchService)
local TaskManager = require(ServerScriptService.Services.TaskManager)
local LightsSystem = require(ServerScriptService.Services.LightsSystem)
local KillSystem = require(ServerScriptService.Services.KillSystem)
local DebugFlags = require(ServerScriptService.Services.DebugFlags)

local RitualService = {}

-- ============================================================
-- TUNING (baselines from docs/DESIGN.md section 9)
-- ============================================================
-- Seconds of held circle needed to complete the Convergence.
local CHANNEL_TIME = 12
-- A kill on a channeler DECAYS progress; it never zeroes it. The Vessel has to
-- keep coming back, in the open, in front of the assembled crew.
local CHANNEL_DECAY_ON_DEATH = 0.33
-- Lit-brazier counts at which the Entity's Rage steps up, and the KILL/SABOTAGE
-- COOLDOWN MULTIPLIER at that step (0.9 = cooldowns 10% shorter). Ascending by
-- `at`; the highest step whose `at` is reached wins.
local RAGE_STEPS = {
	{ at = 3, mult = 0.9 },
	{ at = 5, mult = 0.8 },
	{ at = 7, mult = 0.7 },
}
-- Seconds between RitualStatus heartbeats while armed (state changes broadcast
-- immediately regardless).
local STATUS_TICK = 0.5

-- ============================================================
-- Map contract
-- ============================================================
-- Tag every brazier Part at the séance circle with this and give it a numeric
-- BrazierIndex attribute (1..N, unique). Command Bar, once per part:
--   local p = workspace.Brazier1
--   p:SetAttribute("BrazierIndex", 1)
--   game:GetService("CollectionService"):AddTag(p, "Brazier")
-- Visual children are found BY NAME: a Neon part called "Flame" (Transparency 0
-- lit / 1 unlit), its PointLight (Enabled), and a Fire under it if present.
local BRAZIER_TAG = "Brazier"

-- The circle itself: ONE part tagged this. Its Position is the centre and its
-- Size gives the radius - the endgame happens at the map's centrepiece.
local ZONE_TAG = "ConvergenceZone"

local CREW_ROLE = GameConstants.Roles.Crew

-- ============================================================
-- State
-- ============================================================
-- Sorted ascending by BrazierIndex: { { part = Part, brazierIndex = number } }.
-- Everything below indexes braziers by their POSITION in this array, which equals
-- the BrazierIndex whenever the map numbers them 1..N as intended.
local braziers = {}

-- Ordered stack of lit registry indices, most recently lit on TOP (last element).
-- Desecrate pops from the top; that ordering is the whole point of the stack.
local litStack = {}
local litSet = {} -- registry index -> true, the same set as litStack, for O(1) reads

-- nil until the first read that lands AFTER task assignment memoizes it; see
-- getThreshold for why it is lazy rather than computed at match start.
local threshold = nil
local armed = false
local complete = false
local channelProgress = 0 -- 0..1
local channelRequired = 0
local currentChannelers = {} -- player -> true, refreshed every heartbeat while armed
local channelersPresent = 0

local statusAccum = 0

if DebugFlags.ALL_IMPOSTORS then
	print("[RitualService] ALL_IMPOSTORS is on - there are no crew, so nothing lights braziers or channels.")
end

-- ============================================================
-- Rage hook (the reverse channel to SabotageService - see the header)
-- ============================================================
local rageChangedCallbacks = {}

-- callback(step, mult): step is 0..#RAGE_STEPS, mult is the cooldown multiplier.
function RitualService.OnRageChanged(callback)
	table.insert(rageChangedCallbacks, callback)
end

-- ============================================================
-- Threshold
-- ============================================================
-- Dynamic threshold so small playtests can always arm the ritual: it is the
-- number of tasks the crew actually has to do this match, capped by how many
-- braziers the map physically owns. The map's brazier count is the CEILING, never
-- the requirement (DESIGN.md section 9's baseline of 8 is what a full lobby on the
-- real map lands on naturally).
--
-- LAZY BY NECESSITY, not by preference. MatchService.StartMatch YIELDS at its
-- LoadCharacter loop before it reaches TaskManager.AssignTasks, so anything
-- scheduled from an OnMatchStart callback - a task.defer included - can run
-- mid-yield and read the PREVIOUS match's task count, or zero on a fresh server,
-- which would arm the ritual instantly. So the value is computed on first READ
-- instead: while the total still reads 0 we are inside that pre-assignment
-- window, so return 0 and memoize NOTHING; the first read after assignment is
-- the one that sticks. A 0 threshold can never arm (see armIfReady), and the UI
-- already hides at lit == 0, so a pre-assignment 0 in a snapshot is harmless.
local function getThreshold()
	if threshold ~= nil then
		return threshold
	end

	local totalTasks = TaskManager.GetTotalCount()
	if totalTasks <= 0 then
		return 0
	end

	threshold = math.min(#braziers, totalTasks)

	if threshold < 3 then
		warn(string.format(
			"[RitualService] THRESHOLD IS %d (braziers: %d, tasks assigned: %d) - the ritual arms almost immediately. Tag more Brazier parts and/or register more task stations before judging pacing.",
			threshold, #braziers, totalTasks
		))
	else
		print(string.format("[RitualService] Threshold this match: %d (braziers: %d, tasks assigned: %d)", threshold, #braziers, totalTasks))
	end

	return threshold
end

-- ============================================================
-- Broadcast
-- ============================================================
local function statusPayload()
	return {
		lit = #litStack,
		total = #braziers,
		threshold = getThreshold(),
		armed = armed,
		channelProgress = channelProgress,
		channelRequired = channelRequired,
		channelersPresent = channelersPresent,
		complete = complete,
	}
end

-- Broadcasting to everyone leaks nothing: lit braziers are physically visible in
-- the world, Vessel included - that visibility IS the design.
local function broadcast()
	Remotes.Get(Remotes.Names.RitualStatus):FireAllClients(statusPayload())
	statusAccum = 0
end

-- ============================================================
-- Brazier registry
-- ============================================================
local function buildRegistry()
	braziers = {}

	local seenIndex = {}
	for _, part in ipairs(CollectionService:GetTagged(BRAZIER_TAG)) do
		local index = part:GetAttribute("BrazierIndex")
		if type(index) ~= "number" then
			warn(part:GetFullName(), "is tagged " .. BRAZIER_TAG .. " but has no numeric BrazierIndex attribute - skipping; it will never light.")
		elseif seenIndex[index] then
			warn(
				"Duplicate BrazierIndex", index, "-", seenIndex[index]:GetFullName(), "and", part:GetFullName(),
				"- only the first registers; renumber one of them."
			)
		else
			seenIndex[index] = part
			table.insert(braziers, { part = part, brazierIndex = index })
		end
	end

	table.sort(braziers, function(a, b)
		return a.brazierIndex < b.brazierIndex
	end)
end

-- Toggles ONE brazier's visual children by name. Safe on parts destroyed or taken
-- out of the world since they were tagged.
local function setLit(index, lit)
	local entry = braziers[index]
	if not entry then
		return
	end
	local part = entry.part
	if not part or not part:IsDescendantOf(game) then
		return
	end

	local flame = part:FindFirstChild("Flame")
	if not flame then
		warn(part:GetFullName(), "is a Brazier with no child named 'Flame' - it will track state but show nothing.")
		return
	end

	if flame:IsA("BasePart") then
		flame.Transparency = lit and 0 or 1
	end

	local light = flame:FindFirstChildOfClass("PointLight")
	if light then
		light.Enabled = lit
	end

	local fire = flame:FindFirstChildOfClass("Fire")
	if fire then
		fire.Enabled = lit
	end
end

-- ============================================================
-- The Entity's Rage
-- ============================================================
-- Highest RAGE_STEPS entry the current lit count has reached. Step 0 = neutral.
local function currentRage()
	local step, mult = 0, 1
	for i, entry in ipairs(RAGE_STEPS) do
		if #litStack >= entry.at then
			step, mult = i, entry.mult
		end
	end
	return step, mult
end

-- Pushed on EVERY lit-count change (idempotent - each consumer just stores it).
local function applyRage()
	local step, mult = currentRage()

	KillSystem.SetCooldownMultiplier(mult)
	LightsSystem.SetRageDim(step)
	for _, callback in ipairs(rageChangedCallbacks) do
		callback(step, mult)
	end
end

-- ============================================================
-- Lighting / extinguishing
-- ============================================================
local function armIfReady()
	local required = getThreshold()
	-- A 0 threshold is the pre-assignment window, never a real requirement.
	if required > 0 and not armed and #litStack >= required then
		armed = true
		print(string.format("[RitualService] Threshold reached (%d/%d) - the Convergence is armed.", #litStack, required))
	end
end

-- Lights the LOWEST-index unlit brazier. Returns true if one was lit.
local function lightNext()
	for index = 1, #braziers do
		if not litSet[index] then
			litSet[index] = true
			table.insert(litStack, index)
			setLit(index, true)
			applyRage()
			return true
		end
	end
	return false
end

-- The Vessel's climax comeback tool BY DESIGN: snuffs the MOST RECENTLY lit
-- brazier (the top of the stack), and if that drops the count back under the
-- threshold the ritual disarms and the channel is lost. Returns false if there is
-- nothing lit to take.
function RitualService.Extinguish()
	local index = table.remove(litStack)
	if index == nil then
		return false
	end

	litSet[index] = nil
	setLit(index, false)
	applyRage()

	if armed and #litStack < getThreshold() then
		armed = false
		channelProgress = 0
		channelersPresent = 0
		currentChannelers = {}
		print("[RitualService] Desecration dropped the count below threshold - the Convergence is disarmed and the channel is lost.")
	end

	broadcast()
	return true
end

-- The crew-objective seam MatchService reads (injected by Bootstrap).
function RitualService.IsComplete()
	return complete
end

-- ============================================================
-- The Convergence zone
-- ============================================================
-- Resolved per match alongside the brazier registry, so the heartbeat below never
-- re-scans the tag (and never warn-spams a map that is missing the part).
local zoneCentre = nil
local zoneRadius = 0

local function resolveZone()
	zoneCentre, zoneRadius = nil, 0

	local parts = CollectionService:GetTagged(ZONE_TAG)
	local part = parts[1]
	if not part or not part:IsA("BasePart") then
		warn("[RitualService] No BasePart tagged " .. ZONE_TAG .. " - the Convergence can never be channelled. Tag the séance circle.")
		return
	end
	if #parts > 1 then
		warn("[RitualService] More than one part is tagged " .. ZONE_TAG .. " - using", part:GetFullName())
	end

	-- The circle is a footprint, not a volume: the widest horizontal axis is the
	-- diameter, so standing anywhere on the ring counts regardless of height.
	zoneCentre = part.Position
	zoneRadius = math.max(part.Size.X, part.Size.Z) / 2
end

-- ============================================================
-- Heartbeat: the Convergence channel
-- ============================================================
RunService.Heartbeat:Connect(function(dt)
	if not armed or complete or zoneCentre == nil or MatchService.GetState() ~= "InProgress" then
		return
	end

	local livingCrew = 0
	local present = 0
	local channelers = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if RoleManager.GetRole(player) == CREW_ROLE and RoleManager.IsAlive(player) then
			livingCrew += 1
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and (root.Position - zoneCentre).Magnitude <= zoneRadius then
				present += 1
				channelers[player] = true
			end
		end
	end

	currentChannelers = channelers
	channelersPresent = present
	channelRequired = math.max(2, math.ceil(livingCrew / 2))

	if present >= channelRequired then
		channelProgress = math.min(1, channelProgress + dt / CHANNEL_TIME)
	end
	-- ...otherwise progress HOLDS. Stepping out of the circle costs you time, not
	-- progress - the punishment for absence is the clock, not a rollback.

	if channelProgress >= 1 then
		complete = true
		print("[RitualService] The Convergence completed - the Banishment is done.")
		broadcast()
		MatchService.EvaluateWinCondition("Ritual")
		return
	end

	statusAccum += dt
	if statusAccum >= STATUS_TICK then
		broadcast()
	end
end)

-- ============================================================
-- Interrupt: a kill on a channeler
-- ============================================================
RoleManager.OnAliveChanged(function(player, alive)
	if alive or not armed or complete then
		return
	end
	if not currentChannelers[player] then
		return
	end

	currentChannelers[player] = nil
	channelProgress = math.max(0, channelProgress - CHANNEL_DECAY_ON_DEATH)
	channelersPresent = math.max(0, channelersPresent - 1)
	print(string.format("[RitualService] A channeler died - channel decayed to %.2f.", channelProgress))
	broadcast()
end)

-- ============================================================
-- Task completions light braziers
-- ============================================================
TaskManager.OnTaskCompleted(function()
	if MatchService.GetState() ~= "InProgress" then
		return
	end
	if armed then
		-- Completions past the threshold do nothing while the ritual is already
		-- armed. Whether that surplus should BANK (toward re-arming after a
		-- Desecrate) is a future design question, not a bug.
		return
	end

	if not lightNext() then
		return
	end

	armIfReady()
	broadcast()
end)

-- ============================================================
-- Match lifecycle
-- ============================================================
MatchService.OnMatchStart(function()
	-- Re-read the map here so braziers and a circle tagged after boot still count.
	buildRegistry()
	resolveZone()

	for index = 1, #braziers do
		setLit(index, false)
	end
	litStack = {}
	litSet = {}
	armed = false
	complete = false
	channelProgress = 0
	channelRequired = 0
	channelersPresent = 0
	currentChannelers = {}
	statusAccum = 0

	-- Rage back to neutral for all three consumers.
	applyRage()

	-- Cleared, never computed here: OnMatchStart runs before this match's tasks
	-- are assigned, so the first read after assignment memoizes it (getThreshold).
	threshold = nil

	-- The status stream is AUTHORITATIVE: every state change broadcasts, INCLUDING
	-- this reset. No client or future consumer should ever have to infer a reset
	-- from MatchEnded - they are told.
	broadcast()
end)

-- ============================================================
-- Client-listener timing: the established pattern - fire the snapshot now AND
-- again after 3s, because a joining player's scripts may not have connected their
-- listeners yet at join time.
-- ============================================================
Players.PlayerAdded:Connect(function(player)
	local event = Remotes.Get(Remotes.Names.RitualStatus)
	event:FireClient(player, statusPayload())
	task.delay(3, function()
		if player.Parent == Players then
			event:FireClient(player, statusPayload())
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	currentChannelers[player] = nil
end)

buildRegistry()
resolveZone()

return RitualService
