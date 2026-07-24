--[[
	SabotageBanner.client.lua
	Top-center sabotage banner, sitting just under the RoundStatus banner. Built
	entirely in code (no manually placed Studio GUI objects) so it stays
	version-controlled. Deliberately rough - restyled in the UI rehaul pass.

	Driven purely by the SabotageStatus remote: the server broadcasts on every
	state change and once a second while a critical timer runs, so the countdown
	and the fixed-station count here are live without any local ticking.

	Accepted current behavior: everyone sees the SAME text, impostors included -
	an active sabotage is globally obvious anyway, so there is nothing to hide.
	No sabotage sounds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local UIStyle = require(ReplicatedStorage.Modules.UIStyle)
local sabotageStatusEvent = Remotes.Get(Remotes.Names.SabotageStatus)
local matchEndedEvent = Remotes.Get(Remotes.Names.MatchEnded)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SabotageBannerGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- Directly below RoundStatusUI's pill (10 + 30 + gap), so the two stack cleanly.
local panel = UIStyle.MakePanel(
	screenGui,
	UDim2.fromOffset(420, 30),
	UDim2.new(0.5, 0, 0, 52),
	Vector2.new(0.5, 0)
)
panel.Visible = false

-- Same panel fill as every other surface; the stroke is what reads as alarm.
local panelStroke = panel:FindFirstChildOfClass("UIStroke")
if panelStroke then
	panelStroke.Color = UIStyle.Colors.Negative
	panelStroke.Thickness = 2
end

local label = UIStyle.MakeLabel(panel, "")
label.Size = UDim2.new(1, -UIStyle.Pad * 2, 1, 0)
label.Position = UDim2.new(0, UIStyle.Pad, 0, 0)
label.Font = UIStyle.HeaderFont
label.TextXAlignment = Enum.TextXAlignment.Center
-- Floats over the 3D world, so it takes the stronger banner outline.
label.TextStrokeTransparency = UIStyle.BannerStrokeTransparency

sabotageStatusEvent.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" or data.rejected then
		-- Rejections are a private message to the panel, not a world state.
		return
	end

	if not data.active then
		panel.Visible = false
		return
	end

	if data.type == "Boiler" then
		label.Text = string.format(
			"BOILER OVERLOAD - %ds - valves %d/%d",
			math.max(0, math.ceil(data.timeLeft or 0)),
			data.fixedCount or 0,
			data.totalStations or 0
		)
	elseif data.type == "Lights" then
		label.Text = "The lamps are out - fix the fuse box"
	else
		label.Text = "Something is broken"
	end
	panel.Visible = true
end)

matchEndedEvent.OnClientEvent:Connect(function()
	-- A critical sabotage can be what ENDED the match - don't leave its banner
	-- burning over the end screen.
	panel.Visible = false
end)
