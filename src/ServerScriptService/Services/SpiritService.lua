--[[
	SpiritService.lua
	The dead-player registry. TODAY it does exactly one thing: track which players
	are spirits (dead but still in the match). Nothing more ships in Phase 0.

	Cycle-safety: nothing requires SpiritService except Bootstrap. It requires
	RoleManager and MatchService, neither of which requires it back, and it reacts
	only through their one-directional hooks (OnAliveChanged / OnMatchStart).

	============================================================================
	PHASE 3 SEAM - THE DEAD ARE PLAYERS (docs/DESIGN.md section 6)
	This registry is where all of spirit gameplay lands. When a player is added
	here (on death), that is the moment of:
	  - THE OFFER: the Entity offers every spirit an allegiance - Faithful (bound
	    to the crew) or Hollowed (claimed by the Entity). Chosen once, changeable
	    once per match. The choice is private; the living never see allegiances.
	Hanging off this same registry in Phase 3:
	  - ALLEGIANCE KITS: Faithful "Tend" (steady a lit brazier) vs Hollowed
	    "Muffle" (dampen the Vessel's next Omen).
	  - MEMORIA: ghost-earned currency (bright vs dark Essences at the Forge).
	  - GHOST CHORES: tending braziers, sweeping Memoria motes, attuning the circle.
	  - VEIL-SHOCK RECEPTION: a kill's pulse scatters/blinds nearby spirits; the
	    receiving end lives here.
	  - SEANCE ANSWERS: the anonymous flicker aggregate feeds MeetingSystem's
	    RegisterSeancePhaseHook seam (see that file).
	None of the above exists yet - this file ONLY tracks membership.
	============================================================================
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local RoleManager = require(ServerScriptService.Services.RoleManager)
local MatchService = require(ServerScriptService.Services.MatchService)

local SpiritService = {}

-- Set of current spirits: player -> true.
local spirits = {}

-- True if this player is a registered spirit (dead, still in the match).
function SpiritService.IsSpirit(player)
	return spirits[player] == true
end

-- A fresh array of the current spirits (safe for callers to mutate/iterate).
function SpiritService.GetSpirits()
	local list = {}
	for player in pairs(spirits) do
		table.insert(list, player)
	end
	return list
end

-- A player becomes a spirit the instant they die. THIS is the Offer moment in
-- Phase 3 (see the seam block above); today it only records membership.
RoleManager.OnAliveChanged(function(player, alive)
	if alive == false then
		spirits[player] = true
	end
end)

-- Fresh round: no spirits carry over.
MatchService.OnMatchStart(function()
	spirits = {}
end)

Players.PlayerRemoving:Connect(function(player)
	spirits[player] = nil
end)

return SpiritService
