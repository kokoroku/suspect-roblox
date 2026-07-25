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

GameConstants.Winners = {
	Crew = "CrewWin",
	Vessel = "ImpostorWin",
}

return GameConstants
