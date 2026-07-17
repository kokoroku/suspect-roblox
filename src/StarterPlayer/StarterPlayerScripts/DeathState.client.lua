--[[
	DeathState.client.lua
	Listens for the server telling THIS client they died (killed or
	ejected). Disables ProximityPromptService locally so this player
	stops seeing/triggering ANY prompts - most importantly, the "Report"
	prompt on their own body right after dying.

	NOTE: this currently disables ALL prompts for a dead player, including
	task stations. That's intentional for now - once ghost mode exists
	(dead players can still do tasks), this will need to selectively
	re-enable task prompts only, not report/kill-adjacent ones.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local playerDiedEvent = Remotes.Get(Remotes.Names.PlayerDied)

playerDiedEvent.OnClientEvent:Connect(function()
	ProximityPromptService.Enabled = false
end)
