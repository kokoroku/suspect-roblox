--[[
	MeetingSystem.lua
	Server-authoritative meeting flow: start (via report or emergency call),
	freeze all players, collect votes, tally, eject, resume. Vote tallying
	and ejection ONLY happen here - clients only ever send "I vote for X".
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local RoleManager = require(ServerScriptService.Services.RoleManager)
local TaskManager = require(ServerScriptService.Services.TaskManager)

local MeetingSystem = {}

local MEETING_DURATION = 20 -- seconds to vote before auto-resolving
local MEETING_TABLE_CENTER = Vector3.new(0, 0, 0) -- must match BuildEstateMap.lua's tableCenter
local MEETING_SEAT_RADIUS = 10 -- must match BuildEstateMap.lua's SEAT_RADIUS
local DEAD_BODY_TAG = "DeadBody" -- must match the tag KillSystem applies
local DEFAULT_WALKSPEED = 16
local DEFAULT_JUMPPOWER = 50

local meetingActive = false
local votes = {} -- player -> targetName ("Skip" for skip)
local storedSpeeds = {} -- player -> WalkSpeed before freeze (so SpeedBoost isn't clobbered on unfreeze)
local emergencyMeetingUsed = {} -- player -> true (one emergency call per player per game, for now)

function MeetingSystem.IsMeetingActive()
	return meetingActive
end

local function freezeAllPlayers(frozen)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			continue
		end

		if frozen then
			storedSpeeds[player] = humanoid.WalkSpeed
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
		else
			humanoid.WalkSpeed = storedSpeeds[player] or DEFAULT_WALKSPEED
			humanoid.JumpPower = DEFAULT_JUMPPOWER
			storedSpeeds[player] = nil
		end
	end
end

-- Teleports each alive player to a seat around the meeting table, facing
-- the center, so everyone's gathered and visible (cosmetics included)
-- instead of frozen wherever they happened to be standing.
local function seatPlayersAtTable(alivePlayers)
	local count = #alivePlayers
	for i, player in ipairs(alivePlayers) do
		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local angle = (2 * math.pi * (i - 1)) / count
			local seatX = MEETING_TABLE_CENTER.X + MEETING_SEAT_RADIUS * math.cos(angle)
			local seatZ = MEETING_TABLE_CENTER.Z + MEETING_SEAT_RADIUS * math.sin(angle)
			-- Keep their existing Y (rig height offset) - only move X/Z,
			-- and look toward the table center so everyone faces each other.
			local y = rootPart.Position.Y
			rootPart.CFrame = CFrame.new(Vector3.new(seatX, y, seatZ), Vector3.new(MEETING_TABLE_CENTER.X, y, MEETING_TABLE_CENTER.Z))
		end
	end
end

-- Removes every dead body from the map. Called at the end of every meeting
-- (whether someone was ejected or not) so bodies don't persist across
-- rounds - a "round" is defined as the time between meetings. Destroys the
-- ragdolled character entirely; bringing that player back (ghost mode,
-- lobby respawn) is a separate future feature, not handled here.
local function clearAllBodies()
	for _, root in ipairs(CollectionService:GetTagged(DEAD_BODY_TAG)) do
		local character = root.Parent
		if character then
			character:Destroy()
		end
	end
end

-- reason: "Emergency" or "ReportBody". targetName: victim's name if ReportBody.
-- Returns true/false, and a reason string on failure.
function MeetingSystem.StartMeeting(caller, reason, targetName)
	if meetingActive then
		return false, "MeetingAlreadyActive"
	end

	if not RoleManager.IsAlive(caller) then
		return false, "CallerDead"
	end

	if reason == "Emergency" then
		if emergencyMeetingUsed[caller] then
			return false, "EmergencyAlreadyUsed"
		end
		emergencyMeetingUsed[caller] = true
	end

	meetingActive = true
	votes = {}
	freezeAllPlayers(true)

	local alivePlayerNames = {}
	local alivePlayersList = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if RoleManager.IsAlive(player) then
			table.insert(alivePlayerNames, player.Name)
			table.insert(alivePlayersList, player)
		end
	end

	seatPlayersAtTable(alivePlayersList)

	Remotes.Get(Remotes.Names.MeetingStarted):FireAllClients(reason, targetName, alivePlayerNames, MEETING_DURATION)

	task.delay(MEETING_DURATION, function()
		MeetingSystem.ResolveMeeting()
	end)

	return true
end

-- targetName is nil/false for a Skip vote.
function MeetingSystem.CastVote(voter, targetName)
	if not meetingActive then
		return false, "NoActiveMeeting"
	end
	if not RoleManager.IsAlive(voter) then
		return false, "VoterDead"
	end
	if votes[voter] then
		return false, "AlreadyVoted"
	end

	votes[voter] = targetName or "Skip"

	-- Resolve early if every alive player has voted - no need to wait out the timer.
	local aliveCount = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if RoleManager.IsAlive(player) then
			aliveCount += 1
		end
	end

	local voteCount = 0
	for _ in pairs(votes) do
		voteCount += 1
	end

	if voteCount >= aliveCount then
		MeetingSystem.ResolveMeeting()
	end

	return true
end

function MeetingSystem.ResolveMeeting()
	if not meetingActive then
		return -- already resolved (guards against timer + early-finish race)
	end
	meetingActive = false

	local tally = {} -- name -> count
	for _, target in pairs(votes) do
		tally[target] = (tally[target] or 0) + 1
	end

	local topName, topCount, tie = nil, 0, false
	for name, count in pairs(tally) do
		if count > topCount then
			topName, topCount, tie = name, count, false
		elseif count == topCount then
			tie = true
		end
	end

	local ejectedPlayer = nil
	if topName and topName ~= "Skip" and not tie then
		ejectedPlayer = Players:FindFirstChild(topName)
	end

	local ejectedRole = nil
	if ejectedPlayer then
		ejectedRole = RoleManager.GetRole(ejectedPlayer)
		RoleManager.SetAlive(ejectedPlayer, false)
		Remotes.Get(Remotes.Names.PlayerDied):FireClient(ejectedPlayer)

		-- TODO: replace with a proper "ejected into space" animation/spectate
		-- flow later - for now just take them out of the round.
		local humanoid = ejectedPlayer.Character and ejectedPlayer.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0
		end
	end

	freezeAllPlayers(false)
	clearAllBodies() -- round is over (meeting resolved) - clean the board

	Remotes.Get(Remotes.Names.VoteResult):FireAllClients(
		ejectedPlayer and ejectedPlayer.Name or nil,
		ejectedRole
	)

	-- TODO: once full round-reset flow exists, fire MatchEnded to clients
	-- here instead of just printing.
	local winner = RoleManager.CheckWinCondition(TaskManager.GetRemainingCount())
	if winner then
		print("[MeetingSystem] Win condition reached:", winner)
	end
end

Players.PlayerRemoving:Connect(function(player)
	votes[player] = nil
	storedSpeeds[player] = nil
	emergencyMeetingUsed[player] = nil
end)

return MeetingSystem