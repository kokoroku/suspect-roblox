--[[
	MatchService.lua
	Owns the match lifecycle: starting a round, evaluating the win condition on
	every relevant trigger (kills, meeting resolution, task completion), the
	MatchEnded broadcast, a timed end screen, then an in-place restart.

	IMPORTANT: this module must NEVER require KillSystem, MeetingSystem, or
	PowerupService - those require MatchService. The OnMatchStart hook is the
	reverse channel that keeps the dependency one-directional and cycle-free:
	those services register a reset callback here rather than MatchService
	reaching into their internals.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local RoleManager = require(ServerScriptService.Services.RoleManager)
local TaskManager = require(ServerScriptService.Services.TaskManager)
local DebugFlags = require(ServerScriptService.Services.DebugFlags)

local MatchService = {}

local END_SCREEN_DURATION = 10 -- seconds the end screen shows before restart
-- Minimum players to start a round; raise for real sessions, keep 2 for Studio
-- multi-client tests.
local MIN_PLAYERS = 2
-- Intermission countdown length; tune freely, lower it while iterating.
local INTERMISSION_DURATION = 15

local matchState = "Waiting" -- "Waiting" | "Intermission" | "InProgress" | "Ended"
-- Live seconds remaining in the intermission countdown, read by broadcastStatus.
local intermissionSecondsLeft = 0

function MatchService.GetState()
	return matchState
end

-- Callbacks fired when a match starts. Lets other services reset their own
-- state (bodies cleared, cooldowns wiped, meeting flags reset) without
-- MatchService requiring them - keeps the dependency one-directional and
-- cycle-free.
local onMatchStartCallbacks = {}

function MatchService.OnMatchStart(callback)
	table.insert(onMatchStartCallbacks, callback)
end

-- Builds the RoundStatus payload for the CURRENT state.
local function statusPayload()
	local payload = { state = matchState }
	if matchState == "Waiting" then
		payload.playersPresent = #Players:GetPlayers()
		payload.playersNeeded = MIN_PLAYERS
	elseif matchState == "Intermission" then
		payload.secondsLeft = intermissionSecondsLeft
	end
	return payload
end

local function broadcastStatus()
	Remotes.Get(Remotes.Names.RoundStatus):FireAllClients(statusPayload())
end

-- Fires one player their personal snapshot, with the optional spectator flag.
local function sendStatusTo(player, spectator)
	local payload = statusPayload()
	payload.spectator = spectator
	Remotes.Get(Remotes.Names.RoundStatus):FireClient(player, payload)
end

function MatchService.StartMatch()
	matchState = "InProgress"

	-- Services reset their own state here (bodies cleared, cooldowns wiped,
	-- meeting flags reset) so MatchService doesn't need to know their internals.
	for _, callback in ipairs(onMatchStartCallbacks) do
		callback()
	end

	-- CharacterAutoLoads is off, so this is the (re)spawn for every player.
	for _, player in ipairs(Players:GetPlayers()) do
		player:LoadCharacter()
	end

	RoleManager.AssignRoles(Players:GetPlayers())
	TaskManager.AssignTasks(RoleManager.GetAllCrew())

	broadcastStatus()
end

-- trigger: "Kill" | "MeetingResolved" | "TaskCompleted" | "PlayerLeft"
function MatchService.EvaluateWinCondition(trigger)
	if matchState ~= "InProgress" then
		return
	end

	local total = TaskManager.GetTotalCount()
	-- nil = "no tasks exist this match, the task clause must not fire" -
	-- CheckWinCondition already treats nil that way. Guards the zero-stations
	-- case from instantly ending every match.
	local tasksRemaining = total > 0 and TaskManager.GetRemainingCount() or nil

	-- Completing a task never changes alive counts, so it must never be able to
	-- hand impostors a parity (impostors >= crew) win. This also keeps 2-player
	-- test rounds playable - in a 1v1, parity is true from the first second, and
	-- without this gate the first task completion would instantly end the match
	-- as an impostor win.
	local includeParity = trigger ~= "TaskCompleted"

	local winner = RoleManager.CheckWinCondition(tasksRemaining, includeParity)

	if winner and DebugFlags.ALL_IMPOSTORS then
		-- ALL_IMPOSTORS mode exists to free-test kills and meetings; ending on
		-- every kill would make it useless. Report the would-be winner and stay
		-- in progress.
		print("[MatchService] Win condition reached (ignored in ALL_IMPOSTORS debug mode):", winner)
		return
	elseif winner then
		MatchService.EndMatch(winner)
	end
end

function MatchService.EndMatch(winner)
	matchState = "Ended"

	Remotes.Get(Remotes.Names.MatchEnded):FireAllClients(winner, END_SCREEN_DURATION)
	broadcastStatus()
	-- Timing/progression past here is owned entirely by StartRoundLoop.
end

Players.PlayerAdded:Connect(function(player)
	broadcastStatus() -- keeps the Waiting count live for everyone

	if matchState == "InProgress" then
		-- Late joiner: tell them they're a spectator this round. Repeated after a
		-- short delay because their client scripts may not have connected their
		-- listeners yet at join time.
		sendStatusTo(player, true)
		task.delay(3, function()
			if matchState == "InProgress" and player.Parent == Players then
				sendStatusTo(player, true)
			end
		end)
	end
end)

Players.PlayerRemoving:Connect(function()
	broadcastStatus() -- also ticks the Waiting counter down

	if matchState == "InProgress" then
		-- Defer so every service's own PlayerRemoving cleanup (RoleManager
		-- included) runs first, so the win check sees post-departure counts. An
		-- impostor quitting mid-match now ends the round as a crew win instead of
		-- wedging the server.
		task.defer(function()
			MatchService.EvaluateWinCondition("PlayerLeft")
		end)
	end
end)

-- Called EXACTLY ONCE by Bootstrap. Owns all round timing and progression.
function MatchService.StartRoundLoop()
	task.spawn(function()
		while true do
			-- (a) Wait for enough players.
			matchState = "Waiting"
			broadcastStatus()
			while #Players:GetPlayers() < MIN_PLAYERS do
				task.wait(1)
			end

			-- (b) Intermission. Ghosts and late joiners rejoin the world for the
			-- countdown so the between-rounds window works as a proto-lobby;
			-- survivors of the last match are NOT re-spawned here (StartMatch
			-- respawns everyone anyway).
			matchState = "Intermission"
			for _, player in ipairs(Players:GetPlayers()) do
				if player.Character == nil or not RoleManager.IsAlive(player) then
					player:LoadCharacter()
				end
			end

			-- (c) Countdown, abandoning back to (a) if players drop below minimum.
			local abandoned = false
			for s = INTERMISSION_DURATION, 1, -1 do
				intermissionSecondsLeft = s
				broadcastStatus()
				task.wait(1)
				if #Players:GetPlayers() < MIN_PLAYERS then
					abandoned = true
					break
				end
			end

			if not abandoned then
				-- (d) Start the match.
				MatchService.StartMatch()

				-- (e) Wait for the match to end.
				while MatchService.GetState() == "InProgress" do
					task.wait(0.5)
					if #Players:GetPlayers() == 0 then
						-- Wedge guard: if everyone leaves (including under
						-- DebugFlags.ALL_IMPOSTORS, where matches never end), reset
						-- instead of trapping the next visitor in a dead match.
						matchState = "Waiting"
					end
				end

				-- (f) Hold on the end screen before looping around.
				if MatchService.GetState() == "Ended" then
					-- PLACEHOLDER: this in-place loop-around is what the future lobby
					-- teleport replaces - players will teleport OUT after the end
					-- screen instead of rolling straight into the next intermission.
					task.wait(END_SCREEN_DURATION)
				end
			end

			-- (g) Loop back to (a). With enough players still present, (a) passes
			-- instantly and a fresh intermission begins.
		end
	end)
end

TaskManager.OnTaskCompleted(function()
	MatchService.EvaluateWinCondition("TaskCompleted")
end)

return MatchService
