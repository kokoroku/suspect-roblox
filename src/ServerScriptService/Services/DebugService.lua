--[[
	DebugService.lua
	The runtime, mod-gated control surface for DebugFlags plus a set of one-shot
	debug actions. Replaces the old workflow of editing DebugFlags.lua and
	restarting: flags are now flipped live, from inside a running session, by
	whoever is on the mod list.

	SESSION-ONLY BY CONSTRUCTION. Nothing here persists a flag - DebugFlags is a
	plain table of booleans that resets to its false defaults on every server
	start, so the worst case for a forgotten toggle is one server's lifetime.

	SECURITY MODEL, and it is the only one that counts: IsMod is checked
	server-side on EVERY remote handler in this file. A client hiding or showing a
	menu is cosmetics - a non-mod who fires these remotes by hand is rejected here
	and told nothing. Never move a check to the client, and never add a handler
	that skips one.

	Cycle-safety: this service sits at the TOP of the dependency graph. It requires
	the services it drives; NOTHING requires it back. The one reverse channel is
	KillSystem's mod predicate, which this module injects into KillSystem at the
	bottom of this file rather than KillSystem reaching for DebugService.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local GameConstants = require(ReplicatedStorage.Modules.GameConstants)
local DebugFlags = require(ServerScriptService.Services.DebugFlags)
local MatchService = require(ServerScriptService.Services.MatchService)
local RitualService = require(ServerScriptService.Services.RitualService)
local KillSystem = require(ServerScriptService.Services.KillSystem)
local PowerupOwnershipService = require(ServerScriptService.Services.PowerupOwnershipService)
local PlayerDataService = require(ServerScriptService.Services.PlayerDataService)

local DebugService = {}

-- ============================================================
-- WHO IS A MOD
--
-- >>> ADD YOUR OWN UserId HERE <<< - this list is the entire production access
-- control. Roblox UserIds are numbers, not usernames: e.g. { 123456789 }. Find
-- yours at roblox.com/users/<id>/profile in the URL of your own profile.
--
-- Studio grants mod to EVERYONE, which is a playtesting convenience and nothing
-- more - a Studio session is already fully under the tester's control, so
-- withholding a menu there protects nothing. In a live server the list is the
-- only way in.
-- ============================================================
local MOD_USER_IDS = {}

local modUserIdSet = {}
for _, userId in ipairs(MOD_USER_IDS) do
	modUserIdSet[userId] = true
end

-- The single authority. Every handler below calls this; nothing else decides.
function DebugService.IsMod(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	return modUserIdSet[player.UserId] == true
end

-- ============================================================
-- Flag registry - the menu's labels and copy. Every DebugFlags field appears
-- here; a flag missing from this table is invisible to the menu and cannot be
-- toggled through it, which makes this the one place to add a new one.
-- ============================================================
local FLAG_META = {
	ALL_IMPOSTORS = {
		label = "All Impostors",
		description = "Everyone is the Vessel and may kill each other. Matches never end.",
	},
	GRANT_ALL_POWERUPS = {
		label = "Grant All Charms (on join)",
		description = "Joining players own every Charm at max tier. Applies at join, not retroactively.",
	},
	LIGHTS_TEST_CONTROLS = {
		label = "Lights Test Key (P)",
		description = "P toggles lights-out directly, bypassing the sabotage flow.",
	},
	ASSIGN_ALL_TASKS = {
		label = "Assign All Tasks",
		description = "Every crew player gets every registered task. Applies from the next match.",
	},
	LIVE_LOADOUT = {
		label = "Live Loadout",
		description = "Loadout saves apply mid-match. Breaks the pending/active lock - verify only.",
	},
	GOD_MODE = {
		label = "God Mode (mods)",
		description = "Mods cannot be killed; the attempt is rejected like an invalid target.",
	},
	FAST_INTERMISSION = {
		label = "Fast Intermission",
		description = "Intermission runs 3 seconds. Applies from the next intermission.",
	},
	NO_COOLDOWNS = {
		label = "No Cooldowns",
		description = "Charm, kill and sabotage cooldown gates all pass. Per-match uses still apply.",
	},
}

-- ============================================================
-- Action registry. Each fn(player) drives a DEBUG ONLY entry point on the
-- service that owns the state - this module never reaches into anyone's
-- internals. Every call is pcall-wrapped: a debug tool that errors should
-- report and move on, never take a handler thread down with it.
-- ============================================================
local ACTIONS = {}

ACTIONS.ForceStart = {
	label = "Force Start Match",
	fn = function()
		MatchService.DebugForceStart()
	end,
}

ACTIONS.EndCrewWin = {
	label = "End Match (Crew win)",
	fn = function()
		MatchService.ForceEnd(GameConstants.Winners.Crew)
	end,
}

ACTIONS.EndVesselWin = {
	label = "End Match (Vessel win)",
	fn = function()
		MatchService.ForceEnd(GameConstants.Winners.Vessel)
	end,
}

ACTIONS.LightBraziers = {
	label = "Light Braziers (to threshold)",
	fn = function()
		RitualService.DebugLightAll()
	end,
}

ACTIONS.ExtinguishBraziers = {
	label = "Extinguish All Braziers",
	fn = function()
		RitualService.DebugExtinguishAll()
	end,
}

ACTIONS.GiveCurrency = {
	label = "Give 1000 Currency",
	fn = function(player)
		-- Through the player's PlayerDataService session, exactly as GachaService
		-- spends it: mutate data.currency, mirror onto the Attribute the UI reads,
		-- mark dirty so it saves. Never a bare SetAttribute - that would show a
		-- number the store does not agree with.
		local data = PlayerDataService.Get(player)
		if not data then
			return
		end
		data.currency += 1000
		player:SetAttribute("Currency", data.currency)
		PlayerDataService.MarkDirty(player)
	end,
}

ACTIONS.MaxCharms = {
	label = "Max All Charms",
	fn = function(player)
		PowerupOwnershipService.DebugMaxAll(player)
	end,
}

ACTIONS.KillMe = {
	label = "Kill Me",
	fn = function(player)
		KillSystem.DebugKill(player)
	end,
}

-- ============================================================
-- State reads + broadcast
-- ============================================================
local function flagSnapshot()
	local flags = {}
	for name in pairs(FLAG_META) do
		flags[name] = DebugFlags[name] == true
	end
	return flags
end

local function actionLabels()
	local labels = {}
	for name, action in pairs(ACTIONS) do
		labels[name] = action.label
	end
	return labels
end

-- Mods only, so a menu left open on another mod's screen never drifts out of
-- sync with the flags someone else is flipping.
local function broadcastToMods()
	local snapshot = flagSnapshot()
	local event = Remotes.Get(Remotes.Names.DebugStateChanged)
	for _, player in ipairs(Players:GetPlayers()) do
		if DebugService.IsMod(player) then
			event:FireClient(player, snapshot)
		end
	end
end

-- RemoteFunction body. nil for a non-mod - which doubles as how a client learns
-- not to draw the menu at all.
function DebugService.GetDebugState(player)
	if not DebugService.IsMod(player) then
		return nil
	end
	return {
		flags = flagSnapshot(),
		meta = FLAG_META,
		actions = actionLabels(),
	}
end

-- ============================================================
-- Mutations
-- ============================================================
function DebugService.SetDebugFlag(player, name, value)
	-- Silent rejection on all three counts: a non-mod probing these remotes
	-- learns nothing, not even whether a flag name is real.
	if not DebugService.IsMod(player) then
		return
	end
	if type(name) ~= "string" or FLAG_META[name] == nil then
		return
	end
	if type(value) ~= "boolean" then
		return
	end

	local previous = DebugFlags[name] == true
	DebugFlags[name] = value

	-- THE LOUD WARNING, relocated from module scope to the moment it actually
	-- means something. Only on the OFF -> ON edge: this should mark when a server
	-- stopped behaving normally, not repeat on every idempotent set.
	if value and not previous then
		warn(string.format(
			"[Suspect] DEBUG FLAG ENABLED: %s by %s (UserId %d) - %s",
			name, player.Name, player.UserId, FLAG_META[name].description
		))
	elseif not value and previous then
		print(string.format("[Suspect] Debug flag disabled: %s by %s", name, player.Name))
	end

	broadcastToMods()
end

function DebugService.RunDebugAction(player, name)
	if not DebugService.IsMod(player) then
		return
	end
	local action = type(name) == "string" and ACTIONS[name] or nil
	if not action then
		return
	end

	print(string.format("[Suspect] Debug action: %s by %s", name, player.Name))
	local ok, err = pcall(action.fn, player)
	if not ok then
		warn(string.format("[Suspect] Debug action %s FAILED for %s: %s", name, player.Name, tostring(err)))
	end
end

-- ============================================================
-- The one reverse channel: KillSystem asks "is this player a mod?" for GOD_MODE
-- through a predicate rather than requiring this module, which would be a cycle.
-- Injected here, at the top of the graph, where the dependency already points
-- the right way.
-- ============================================================
KillSystem.SetModPredicate(DebugService.IsMod)

if #MOD_USER_IDS == 0 and not RunService:IsStudio() then
	warn("[Suspect] DebugService: MOD_USER_IDS is empty and this is not Studio - NOBODY can open the debug menu. Add your UserId in DebugService.lua.")
end

return DebugService
