--[[
	Remotes.lua
	Central list of RemoteEvent/RemoteFunction names so client and server
	never have to guess string names. Server creates them on boot;
	client just waits for them to exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

Remotes.Names = {
	-- Client -> Server actions (server validates everything)
	CompleteTask = "CompleteTask",
	AttemptKill = "AttemptKill",
	ReportBody = "ReportBody",
	CastVote = "CastVote",
	UsePowerup = "UsePowerup",
	RollGacha = "RollGacha",
	SetLoadout = "SetLoadout",
	UpgradePowerup = "UpgradePowerup",
	DebugToggleLights = "DebugToggleLights",
	TaskFinished = "TaskFinished",
	TaskCancel = "TaskCancel",
	TriggerSabotage = "TriggerSabotage",
	-- Mod debug menu (DebugService is the only handler, and it re-validates mod
	-- status on every one of these - the hidden menu is not the lock).
	SetDebugFlag = "SetDebugFlag",
	RunDebugAction = "RunDebugAction",

	-- Server -> Client notifications
	RoleAssigned = "RoleAssigned",
	PlayerDied = "PlayerDied",
	KillFeedback = "KillFeedback",
	MeetingStarted = "MeetingStarted",
	VoteResult = "VoteResult",
	MatchEnded = "MatchEnded",
	GachaResult = "GachaResult",
	LoadoutResult = "LoadoutResult",
	InventoryUpdated = "InventoryUpdated",
	TasksUpdated = "TasksUpdated",
	TaskOpen = "TaskOpen",
	TaskResult = "TaskResult",
	SpectateTargetsUpdated = "SpectateTargetsUpdated",
	RoundStatus = "RoundStatus",
	UpgradeResult = "UpgradeResult",
	LoadoutApplied = "LoadoutApplied",
	PowerupUseResult = "PowerupUseResult",
	PowerupEffect = "PowerupEffect",
	SeerResult = "SeerResult",
	LightsChanged = "LightsChanged",
	SabotageStatus = "SabotageStatus",
	-- RitualStatus payload (RitualService is the only sender):
	--   { lit, total, threshold, armed, channelProgress (0..1), channelRequired,
	--     channelersPresent, complete }
	RitualStatus = "RitualStatus",
	-- OmenEvent payload (OmenService is the only sender - docs/DESIGN.md section 7,
	-- the Omen law: every activation emits a public tell):
	--   { omenType (string), position (Vector3), intensity ("Common"|"Rare"|"Epic"),
	--     sourceUserId (number) }
	-- Sent ONLY to players inside the intensity's radius, the source included.
	OmenEvent = "OmenEvent",
	-- The full debug flag table after any change, broadcast by DebugService to
	-- CURRENT MODS ONLY so their open menus stay in sync with each other.
	DebugStateChanged = "DebugStateChanged",
	-- DebugToggleLights, PowerupEffect, SeerResult and LightsChanged are wired
	-- by the effects/lights work that follows this change - declared now so this
	-- file is only touched once.
}

-- RemoteFunctions (client invokes, server answers) - a request/response pair,
-- unlike the fire-and-forget RemoteEvents above.
Remotes.FunctionNames = {
	GetGachaCatalog = "GetGachaCatalog",
	-- Returns nil to anyone who is not a mod - which is also how a client learns
	-- it should not draw the debug menu at all.
	GetDebugState = "GetDebugState",
}

-- Call from the server once, on boot, to create every remote.
function Remotes.CreateAll()
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end

	for _, name in pairs(Remotes.Names) do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end

	for _, name in pairs(Remotes.FunctionNames) do
		if not folder:FindFirstChild(name) then
			local remoteFunction = Instance.new("RemoteFunction")
			remoteFunction.Name = name
			remoteFunction.Parent = folder
		end
	end

	return folder
end

-- Call from client or server to safely fetch a remote (yields until it exists).
function Remotes.Get(name)
	local folder = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not folder then
		error("Remotes folder never appeared - did the server call Remotes.CreateAll()?")
	end
	return folder:WaitForChild(name, 10)
end

return Remotes