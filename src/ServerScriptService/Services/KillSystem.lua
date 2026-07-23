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
local PhysicsService = game:GetService("PhysicsService")
local Debris = game:GetService("Debris")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local RoleManager = require(ServerScriptService.Services.RoleManager)
local MatchService = require(ServerScriptService.Services.MatchService)
local DebugFlags = require(ServerScriptService.Services.DebugFlags)

local KillSystem = {}

local KILL_RANGE = 7 -- studs
local KILL_COOLDOWN_SECONDS = 25
local DEAD_BODY_TAG = "DeadBody"
local RAGDOLL_COLLISION_GROUP = "RagdollParts"
local DEATH_SOUND_ID = "rbxasset://sounds/uuhhh.mp3" -- classic Roblox death sound; swap out later for custom SFX

-- player -> cooldownUntil (os.clock())
local killCooldowns = {}

-- Callbacks fired after a kill is fully performed. Same one-directional hook
-- pattern as MeetingSystem.OnMeetingStart - lets services react to a kill (e.g.
-- PowerupService revealing the killer) without KillSystem requiring them.
local killPerformedCallbacks = {}

function KillSystem.OnKillPerformed(callback)
	table.insert(killPerformedCallbacks, callback)
end

-- ============================================================
-- One-time setup: ragdoll parts collide with the world/other players
-- normally, but NOT with each other. Without this, a resting rig's
-- naturally-overlapping limbs violently push each other apart the instant
-- collision turns on - that's what caused the "exploding" body.
-- ============================================================
local function ensureCollisionGroup()
	pcall(function()
		PhysicsService:RegisterCollisionGroup(RAGDOLL_COLLISION_GROUP)
	end)
	PhysicsService:CollisionGroupSetCollidable(RAGDOLL_COLLISION_GROUP, RAGDOLL_COLLISION_GROUP, false)
end
ensureCollisionGroup()

local function getDistance(playerA, playerB)
	local rootA = playerA.Character and playerA.Character:FindFirstChild("HumanoidRootPart")
	local rootB = playerB.Character and playerB.Character:FindFirstChild("HumanoidRootPart")
	if not rootA or not rootB then
		return math.huge
	end
	return (rootA.Position - rootB.Position).Magnitude
end

local function playDeathSound(character)
	local head = character:FindFirstChild("Head")
	if not head then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = DEATH_SOUND_ID
	sound.Volume = 1
	sound.Parent = head
	sound:Play()
	Debris:AddItem(sound, 5)
end

-- Turns a just-killed player's character into a real, connected R6 ragdoll.
-- Every Motor6D (RootJoint, Neck, shoulders, hips) becomes a
-- BallSocketConstraint with modest rotation limits (keeps the body looking
-- anatomically plausible and reduces floor clipping vs. fully free joints).
-- Parts collide with the world/other players but NOT each other (see
-- ensureCollisionGroup), which is what stops the ragdoll from exploding.
-- Tagged on Torso - since it stays constraint-connected to the whole body
-- rather than detached, the report prompt correctly follows it as it tumbles.
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

	local animateScript = character:FindFirstChild("Animate")
	if animateScript then
		animateScript:Destroy()
	end

	playDeathSound(character)

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
				socket.LimitsEnabled = true
				socket.UpperAngle = 45 -- keeps joints from bending into unnatural, floor-clipping poses
				socket.TwistLimitsEnabled = true
				socket.TwistUpperAngle = 45
				socket.TwistLowerAngle = -45
				socket.Parent = part0
			end
			descendant:Destroy()
		elseif descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			descendant.CanCollide = true
			descendant.CollisionGroup = RAGDOLL_COLLISION_GROUP
		end
	end

	-- Fully kill the Humanoid now that joints are already replaced - this
	-- stops its internal stabilization/balancing logic, which is what was
	-- causing the perpetual flailing and slow crawl across the floor even
	-- with PlatformStand on. Safe to do now since BreakJointsOnDeath has
	-- nothing left to act on (we already destroyed the Motor6Ds ourselves).
	if humanoid then
		humanoid.Health = 0
	end

	local torso = character:FindFirstChild("Torso") -- R6
	if torso then
		torso:SetAttribute("VictimName", targetPlayer.Name)
		CollectionService:AddTag(torso, DEAD_BODY_TAG)
	end

	-- Tell the victim's own client they're dead, so it can suppress
	-- ProximityPrompts (report/task prompts) showing on their own screen -
	-- otherwise they see a "Report" prompt for their own body immediately.
	Remotes.Get(Remotes.Names.PlayerDied):FireClient(targetPlayer)
end

-- Called from the AttemptKill RemoteEvent handler.
-- Returns true/false, and a reason string on failure.
function KillSystem.AttemptKill(killer, target)
	if MatchService.GetState() ~= "InProgress" then
		return false, "MatchNotInProgress"
	end

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

	if RoleManager.GetRole(target) == "Impostor" and not DebugFlags.ALL_IMPOSTORS then
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

	MatchService.EvaluateWinCondition("Kill")

	for _, callback in ipairs(killPerformedCallbacks) do
		callback(killer, target)
	end

	return true
end

Players.PlayerRemoving:Connect(function(player)
	killCooldowns[player] = nil
end)

MatchService.OnMatchStart(function()
	killCooldowns = {}
end)

return KillSystem