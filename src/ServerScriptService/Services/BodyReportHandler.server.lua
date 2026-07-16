--[[
	BodyReportHandler.server.lua
	Auto-wires a ProximityPrompt onto every Part tagged "DeadBody" (set by
	KillSystem when someone dies) so any player can walk up and report it.
	Same pattern as TaskStationHandler - no manual scripting needed per body,
	since bodies are created dynamically at runtime rather than placed by hand.
]]

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local MeetingSystem = require(ServerScriptService.Services.MeetingSystem)

local TAG = "DeadBody"

local function setupBody(root)
	local prompt = root:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Report"
		prompt.ObjectText = "Body"
		prompt.HoldDuration = 0.5
		prompt.Parent = root
	end

	local connection
	connection = prompt.Triggered:Connect(function(player)
		local victimName = root:GetAttribute("VictimName")
		local success, reason = MeetingSystem.StartMeeting(player, "ReportBody", victimName)
		if success then
			connection:Disconnect() -- prevent re-reporting the same body mid-meeting
		else
			warn(player.Name, "failed to report body -", reason)
		end
	end)
end

for _, root in ipairs(CollectionService:GetTagged(TAG)) do
	setupBody(root)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(setupBody)
