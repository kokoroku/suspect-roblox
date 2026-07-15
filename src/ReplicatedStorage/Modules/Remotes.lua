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
	CallMeeting = "CallMeeting",
	CastVote = "CastVote",
	UsePowerup = "UsePowerup",
	RollGacha = "RollGacha",

	-- Server -> Client notifications
	RoleAssigned = "RoleAssigned",
	MeetingStarted = "MeetingStarted",
	VoteResult = "VoteResult",
	MatchEnded = "MatchEnded",
	GachaResult = "GachaResult",
	InventoryUpdated = "InventoryUpdated",
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
