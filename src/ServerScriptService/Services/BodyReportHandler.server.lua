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
local SabotageService = require(ServerScriptService.Services.SabotageService)

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

	-- Custom prompt UI: replaced by the pixel keybind renderer (PromptUI.client).
	-- Set on every setup (not just when we create the prompt) so an editor-placed
	-- prompt still gets the custom style and the exact label.
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.ActionText = "Report body"

	-- E-only world interaction (see TaskStationHandler's ClickablePrompt comment for
	-- the rule + mobile debt): a stray click filing a report is the same
	-- click-through misfire class.
	prompt.ClickablePrompt = false

	local connection
	connection = prompt.Triggered:Connect(function(player)
		-- Only a CRITICAL sabotage blocks reporting - the body keeps until the
		-- boiler is dealt with. A non-critical sabotage (lights) must not stop a
		-- report, or an impostor could sabotage to sit on a corpse indefinitely.
		if SabotageService.IsCriticalActive() then
			warn(player.Name, "failed to report body -", "FixTheBoiler")
			return
		end

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
