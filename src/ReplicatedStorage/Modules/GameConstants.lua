--[[
	GameConstants.lua
	The single home for internal identifier literals that are shared across
	services and clients: the role ids and the match-winner values.

	These are INTERNAL ids, not display strings. The Séance re-theme (see
	docs/DESIGN.md) later changes DISPLAY strings only - what a crewmate is
	called on screen ("Crew"), what the impostor is called ("Vessel") - while
	these ids stay byte-stable so no comparison, remote payload or saved value
	has to change. Keeping the ids in one place, decoupled from the labels, is
	the entire point of this module.

	No requires: this must be loadable from both server and client with no
	dependencies.
]]

local GameConstants = {}

GameConstants.Roles = {
	Crew = "Crewmate",
	Vessel = "Impostor",
}

-- Display labels for the internal role ids above. THE DISPLAY LAYER READS THIS
-- MAP AND NEVER THE IDS: an id like "Impostor" is a stable comparison value and a
-- persisted one, so it must never reach a player's screen just because it happens
-- to be a readable English word.
--
-- Partial by design today - only the surfaces re-themed so far go through it. The
-- fuller terminology sweep (end screen, meeting wording, every remaining label)
-- happens at the identity pass and will consume this same map rather than adding
-- its own.
GameConstants.RoleDisplayNames = {
	[GameConstants.Roles.Crew] = "Crew",
	[GameConstants.Roles.Vessel] = "Vessel",
}

GameConstants.Winners = {
	Crew = "CrewWin",
	Vessel = "ImpostorWin",
}

return GameConstants
