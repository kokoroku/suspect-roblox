--[[
	EmergencyButtonHandler.server.lua
	Auto-wires EVERY Part tagged "EmergencyButton" in Workspace to MeetingSystem.
	You do not need to add a script to each button part - just tag it.
	Setup for a new emergency button (no scripting required):
	  1. Place a Part in Workspace (e.g. the button on the meeting table)
	  2. Insert a ProximityPrompt into that part (right-click part in
	     Explorer -> Insert Object -> ProximityPrompt)
	  3. Tag the part with "EmergencyButton" - easiest way: paste this into
	     the Command Bar (View -> Command Bar) once per part:
	       game:GetService("CollectionService"):AddTag(workspace.EmergencyButton, "EmergencyButton")
	     (swap "EmergencyButton" for your part's actual name)
]]

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local MeetingSystem = require(ServerScriptService.Services.MeetingSystem)

local TAG = "EmergencyButton"

local function setupButton(part)
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		warn(part:GetFullName(), "is tagged EmergencyButton but has no ProximityPrompt - skipping")
		return
	end

	-- Configure the prompt so tagged map parts need no manual setup. No dead/
	-- distance/cooldown checks here: MeetingSystem.StartMeeting already rejects
	-- dead callers (and the match-state / meeting-active / emergency-used gates),
	-- and ProximityPrompt triggers are engine-validated for range.
	prompt.ActionText = "Call Emergency Meeting"
	prompt.HoldDuration = 0.5
	-- E-only world interaction (see TaskStationHandler's ClickablePrompt comment for
	-- the rule + mobile debt): a stray click calling a meeting is the same
	-- click-through misfire class.
	prompt.ClickablePrompt = false

	prompt.Triggered:Connect(function(player)
		local success, reason = MeetingSystem.StartMeeting(player, "Emergency", nil)
		if not success then
			warn(player.Name, "failed to call emergency meeting", "-", reason)
		end
	end)
end

for _, part in ipairs(CollectionService:GetTagged(TAG)) do
	setupButton(part)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(setupButton)
