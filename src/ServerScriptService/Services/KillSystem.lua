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

-- Turns a just-killed player's character into a reportable "body" - a REAL
-- physics ragdoll (not just BreakJoints, which leaves the Humanoid fighting
-- to hold the character in place and looks "stuck"). Replaces every Motor6D
-- with a BallSocketConstraint so the body stays physically connected and
-- actually tumbles/settles - the ProximityPrompt on the root part then
-- correctly follows it since it's part of the same simulated physics group.
local function turnIntoBody(targetPlayer)
	local character = targetPlayer.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = true -- stop the Humanoid from fighting the ragdoll physics
		humanoid.AutoRotate = false
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("Motor6D") then
			local part0, part1 = descendant.Part0, descendant.Part1
			if part0 and part1 then
				local attachment0 = Instance.new("Attachment")
				attachment0.CFrame = descendant.C0
				attachment0.Parent = part0

				local attachment1 = Instance.new("Attachment")
				attachment1.CFrame = descendant.C1
				attachment1.Parent = part1

				local socket = Instance.new("BallSocketConstraint")
				socket.Attachment0 = attachment0
				socket.Attachment1 = attachment1
				socket.Parent = part0
			end
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = true
			descendant.Massless = false
		end
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		root:SetAttribute("VictimName", targetPlayer.Name)
		CollectionService:AddTag(root, DEAD_BODY_TAG)

		-- CRITICAL: without this, network ownership of the physics stays
		-- with the (now-dead) player's client, and the constraints above
		-- never actually get simulated - the body just freezes/drops in
		-- place instead of tumbling. Handing ownership to the server fixes
		-- that and also makes the ragdoll behave consistently for everyone
		-- watching, not just the owning client.
		local ok = pcall(function()
			root:SetNetworkOwner(nil)
		end)
		if not ok then
			warn("Could not set server network ownership for ragdoll of", targetPlayer.Name)
		end
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