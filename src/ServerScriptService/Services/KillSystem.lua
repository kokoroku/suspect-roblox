--[[
	KillSystem.lua
	Server-authoritative kill resolution. The client only ever sends
	"I want to kill this player" - role check, alive check, proximity,
	and cooldown are ALL validated here. Never trust a client claiming
	a kill already happened.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local RoleManager = require(ServerScriptService.Services.RoleManager)
local TaskManager = require(ServerScriptService.Services.TaskManager)

local KillSystem = {}

local KILL_RANGE = 7 -- studs
local KILL_COOLDOWN_SECONDS = 25
local DEAD_BODY_TAG = "DeadBody"

-- player -> cooldownUntil (os.clock())
local killCooldowns = {}

local function getDistance(playerA, playerB)
	local rootA = playerA.Character and playerA.Character:FindFirstChild("HumanoidRootPart")
	local rootB = playerB.Character and playerB.Character:FindFirstChild("HumanoidRootPart")
	if not rootA or not rootB then
		return math.huge
	end
	return (rootA.Position - rootB.Position).Magnitude
end

-- Turns a just-killed player's character into a reportable "body" - ragdolls
-- it and tags it so MeetingSystem's report flow can find it later, reusing
-- the same CollectionService-tag pattern as TaskStationHandler.
local function turnIntoBody(targetPlayer)
	local character = targetPlayer.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end

	character:BreakJoints() -- ragdoll - this becomes the reportable "body"

	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		root:SetAttribute("VictimName", targetPlayer.Name)
		CollectionService:AddTag(root, DEAD_BODY_TAG)
	end
end

-- Called from the AttemptKill RemoteEvent handler.
-- Returns true/false, and a reason string on failure.
function KillSystem.AttemptKill(killer, target)
	if not target or killer == target then
		return false, "InvalidTarget"
	end

	if RoleManager.GetRole(killer) ~= "Impostor" then
		return false, "NotImpostor"
	end

	if not RoleManager.IsAlive(killer) then
		return false, "KillerDead"
	end

	if not RoleManager.IsAlive(target) then
		return false, "TargetAlreadyDead"
	end

	if RoleManager.GetRole(target) == "Impostor" then
		return false, "CannotKillImpostor"
	end

	if os.clock() < (killCooldowns[killer] or 0) then
		return false, "OnCooldown"
	end

	if getDistance(killer, target) > KILL_RANGE then
		return false, "TooFar"
	end

	RoleManager.SetAlive(target, false)
	turnIntoBody(target)
	killCooldowns[killer] = os.clock() + KILL_COOLDOWN_SECONDS

	-- TODO: once MeetingSystem/round-flow exists, replace this print with
	-- actually ending the round and showing results to all players.
	local winner = RoleManager.CheckWinCondition(TaskManager.GetRemainingCount())
	if winner then
		print("[KillSystem] Win condition reached:", winner)
	end

	return true
end

Players.PlayerRemoving:Connect(function(player)
	killCooldowns[player] = nil
end)

return KillSystem
