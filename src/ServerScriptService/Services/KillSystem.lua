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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
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

-- Turns a just-killed player's character into a reportable "body" - the
-- simple, known-working ragdoll approach (Humanoid Physics state +
-- BreakJoints), plus collision enabled so it can be pushed around. Tagged
-- on the HumanoidRootPart so MeetingSystem's report flow can find it.
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

	-- Only addition vs. the original version: enable collision so the body
	-- can actually be shoved/pushed around by other players instead of
	-- everyone walking straight through it. Deliberately NOT replacing
	-- joints with constraints and NOT touching network ownership - both
	-- of those looked correct in theory but caused the body to freeze in
	-- place instead of tumbling, almost certainly a quirk of how Studio's
	-- local multi-client test tool simulates server/client physics
	-- ownership differently than a real published server would.
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = true
		end
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		root:SetAttribute("VictimName", targetPlayer.Name)
		CollectionService:AddTag(root, DEAD_BODY_TAG)
	end

	-- Tell the victim's own client they're dead, so it can suppress
	-- ProximityPrompts (report/task prompts) showing on their own screen -
	-- otherwise they see a "Report" prompt for their own body immediately.
	Remotes.Get(Remotes.Names.PlayerDied):FireClient(targetPlayer)
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

	if RoleManager.GetRole(target) == "Impostor" and not RoleManager.IsDebugAllImpostorMode() then
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