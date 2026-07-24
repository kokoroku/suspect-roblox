--[[
	SabotageStationHandler.server.lua
	Auto-wires EVERY Part tagged "SabotageStation" in Workspace to
	SabotageService. Same CollectionService pattern as TaskStationHandler - you
	do not need a script per part, just a tag and two attributes.
	Setup for a new fix station (no scripting required):
	  1. Place a Part in Workspace and insert a ProximityPrompt into it
	  2. Add attribute SabotageType (string): "Lights" or "Boiler"
	  3. Add attribute FixId (string): the RESERVED fix task id for that station -
	     "Sabotage:Lights", "Sabotage:Boiler1" or "Sabotage:Boiler2" (the exact
	     keys in SabotageService's Sabotages table)
	  4. Tag the part "SabotageStation" - easiest way, once per part, via the
	     Command Bar (View -> Command Bar):
	       game:GetService("CollectionService"):AddTag(workspace.FuseBox, "SabotageStation")

	Prompts start DISABLED and are only enabled while THEIR sabotage is active
	and their own station is still unfixed - the station's E prompt appearing IS
	the "go fix this" signal.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local SabotageService = require(ServerScriptService.Services.SabotageService)

local TAG = "SabotageStation"

local function setupStation(part)
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		warn(part:GetFullName(), "is tagged SabotageStation but has no ProximityPrompt - skipping")
		return
	end

	local sabotageType = part:GetAttribute("SabotageType")
	local fixId = part:GetAttribute("FixId")
	if type(sabotageType) ~= "string" or type(fixId) ~= "string" then
		warn(part:GetFullName(), "is tagged SabotageStation but is missing its SabotageType and/or FixId attribute - skipping")
		return
	end

	-- Registering hands back which fix minigame this station opens; nil means the
	-- FixId isn't one of the reserved station ids (RegisterFixStation warns).
	local fixType = SabotageService.RegisterFixStation(fixId, part, sabotageType)
	if not fixType then
		return
	end

	prompt.ActionText = "Fix"
	-- Single press opens the fix minigame window client-side, exactly like a task
	-- station. HoldDuration 0 = instant trigger on press.
	prompt.HoldDuration = 0
	-- E-only world interaction (see TaskStationHandler's ClickablePrompt comment
	-- for the rule + the mobile debt): clicks leaking through an open fix window
	-- into the prompt behind it would re-trigger the station.
	prompt.ClickablePrompt = false
	-- Off until this station's sabotage is actually running.
	prompt.Enabled = false

	-- Drive the prompt off the same hook that drives the SabotageStatus
	-- broadcast, NOT off the remote: this is the server's own state, and the
	-- server must never take a client's word for whether a station is live. Fires
	-- on activate, on each station fixed, and on resolve.
	SabotageService.RegisterOnSabotageChanged(function(changedType, isActive)
		prompt.Enabled = isActive and changedType == sabotageType and not SabotageService.IsStationFixed(fixId)
	end)

	prompt.Triggered:Connect(function(player)
		-- Re-triggering an already-open fix is a no-op, never a restart (same rule
		-- as task stations - TaskCancel clears the session when the window closes).
		if SabotageService.HasFixSession(player, fixId) then
			return
		end

		local ok, reason = SabotageService.StartFix(player, fixId)
		if ok then
			-- Fixes ride the client task pipeline: TaskOpen pops the minigame, and
			-- completion comes back as TaskFinished, which Bootstrap routes to
			-- SabotageService.TryFinishFix because it owns this player's session.
			Remotes.Get(Remotes.Names.TaskOpen):FireClient(player, fixId, fixType, part.Position)
		else
			warn(player.Name, "failed to start fix", fixId, "-", reason)
		end
	end)
end

for _, part in ipairs(CollectionService:GetTagged(TAG)) do
	setupStation(part)
end

CollectionService:GetInstanceAddedSignal(TAG):Connect(setupStation)
