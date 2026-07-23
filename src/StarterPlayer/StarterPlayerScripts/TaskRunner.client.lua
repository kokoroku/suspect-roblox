--[[
	TaskRunner.client.lua
	Owns the single task minigame window. When the server opens a task (TaskOpen),
	this pops one centered window, hands the content frame to the minigame module
	named by the task's def, and relays success back up (TaskFinished). The server
	answers with TaskResult, which we flash and then close on.

	Built entirely in code (matches MeetingUI's house style) - deliberately rough,
	it gets restyled in the UI rehaul. The actual minigames live as child
	ModuleScripts under the TaskMinigames folder next to this script; each one is
	responsible for its own UI inside the content frame (see Placeholder for the
	Build/cleanup contract).

	Does NOT touch camera, movement, or ProximityPromptService - movement stays
	free; walking too far from the station just cancels the window (no freeze).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Modules.Remotes)
local TaskDefs = require(ReplicatedStorage.Modules.TaskDefs)

local taskOpenEvent = Remotes.Get(Remotes.Names.TaskOpen)
local taskResultEvent = Remotes.Get(Remotes.Names.TaskResult)
local taskFinishedEvent = Remotes.Get(Remotes.Names.TaskFinished)
local meetingStartedEvent = Remotes.Get(Remotes.Names.MeetingStarted)
local playerDiedEvent = Remotes.Get(Remotes.Names.PlayerDied)

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Minigame modules live in a sibling folder to this script.
local minigamesFolder = script.Parent:WaitForChild("TaskMinigames")

local CANCEL_RANGE = 10

-- ============================================================
-- Build the window once. Enabled only while a task is open.
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TaskRunnerGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.Parent = playerGui

local window = Instance.new("Frame")
window.Size = UDim2.new(0, 420, 0, 320)
window.Position = UDim2.new(0.5, -210, 0.5, -160)
window.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
window.BackgroundTransparency = 0.1
window.Parent = screenGui

-- ---- Title bar (task name + close button) ----
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
titleBar.Parent = window

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -40, 1, 0)
titleLabel.Position = UDim2.new(0, 8, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.TextColor3 = Color3.new(1, 1, 1)
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.TextScaled = true
titleLabel.Font = Enum.Font.GothamBold
titleLabel.Text = "Task"
titleLabel.Parent = titleBar

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.new(0, 32, 0, 32)
closeButton.Position = UDim2.new(1, -34, 0, 2)
closeButton.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
closeButton.TextColor3 = Color3.new(1, 1, 1)
closeButton.TextScaled = true
closeButton.Font = Enum.Font.GothamBold
closeButton.Text = "X"
closeButton.Parent = titleBar

-- ---- Content frame (the minigame builds itself in here) ----
local contentFrame = Instance.new("Frame")
contentFrame.Size = UDim2.new(1, 0, 1, -36)
contentFrame.Position = UDim2.new(0, 0, 0, 36)
contentFrame.BackgroundTransparency = 1
contentFrame.Parent = window

-- ---- Status line (waiting/result/reason overlay along the bottom) ----
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 28)
statusLabel.Position = UDim2.new(0, 0, 1, -28)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
statusLabel.TextScaled = true
statusLabel.Font = Enum.Font.Gotham
statusLabel.Text = ""
statusLabel.ZIndex = 5
statusLabel.Parent = window

-- ============================================================
-- Open-window state. `openToken` bumps on every open/close so any pending
-- async work (walk poll, result flash timers) can tell if it's stale.
-- ============================================================
local openToken = 0
local currentTaskId = nil
local currentCleanup = nil
local finished = false -- guards onComplete against double-firing TaskFinished

local function closeWindow()
	openToken += 1
	if currentCleanup then
		local ok, err = pcall(currentCleanup)
		if not ok then
			warn("TaskRunner: minigame cleanup errored -", err)
		end
		currentCleanup = nil
	end
	currentTaskId = nil
	finished = false
	statusLabel.Text = ""
	screenGui.Enabled = false
end

local function openWindow(taskId, taskType, stationPos)
	-- Only one window at a time - tear down any existing one first.
	if currentTaskId then
		closeWindow()
	end

	openToken += 1
	local myToken = openToken
	currentTaskId = taskId
	finished = false
	statusLabel.Text = ""

	local def = TaskDefs.Get(taskType)
	titleLabel.Text = def.displayName

	-- Resolve the minigame module by name; fall back to Placeholder if it's
	-- missing (every def currently points at Placeholder anyway).
	local moduleScript = minigamesFolder:FindFirstChild(def.module)
	if not moduleScript then
		warn("TaskRunner: minigame module '" .. tostring(def.module) .. "' not found - falling back to Placeholder")
		moduleScript = minigamesFolder:FindFirstChild("Placeholder")
	end
	if not moduleScript then
		warn("TaskRunner: Placeholder minigame missing - cannot open task")
		closeWindow()
		return
	end

	local minigame = require(moduleScript)

	-- The minigame calls this once when the player succeeds. We report to the
	-- server and drop into a waiting state until TaskResult comes back.
	local onComplete = function()
		if finished then
			return
		end
		finished = true
		taskFinishedEvent:FireServer(taskId)
		statusLabel.Text = "Waiting..."
	end

	local ok, cleanupOrErr = pcall(function()
		return minigame.Build(contentFrame, def.config, onComplete)
	end)
	if ok then
		currentCleanup = cleanupOrErr
	else
		warn("TaskRunner: minigame Build errored -", cleanupOrErr)
	end

	screenGui.Enabled = true

	-- Walk-away cancel: movement is allowed, distance cancels - no freeze.
	task.spawn(function()
		while openToken == myToken do
			task.wait(0.2)
			if openToken ~= myToken then
				break
			end
			local character = localPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and (root.Position - stationPos).Magnitude > CANCEL_RANGE then
				closeWindow()
				break
			end
		end
	end)
end

-- ============================================================
-- Server drives the window open.
-- ============================================================
taskOpenEvent.OnClientEvent:Connect(function(taskId, taskType, stationPos)
	openWindow(taskId, taskType, stationPos)
end)

-- ============================================================
-- Server verdict on a finished task.
-- ============================================================
taskResultEvent.OnClientEvent:Connect(function(taskId, ok, reason)
	if taskId ~= currentTaskId then
		return
	end

	if ok then
		statusLabel.Text = "Done!"
		local myToken = openToken
		task.delay(0.6, function()
			if openToken == myToken then
				closeWindow()
			end
		end)
	else
		local msg
		if reason == "NotAllowedNow" then
			msg = "Can't do tasks right now"
		elseif reason == "TooFar" then
			msg = "Too far from the station"
		else
			msg = tostring(reason)
		end
		statusLabel.Text = msg
		local myToken = openToken
		task.delay(0.8, function()
			if openToken == myToken then
				closeWindow()
			end
		end)
	end
end)

-- ============================================================
-- Everything that should abandon an open task window.
-- ============================================================
closeButton.MouseButton1Click:Connect(function()
	if currentTaskId then
		closeWindow()
	end
end)

meetingStartedEvent.OnClientEvent:Connect(function()
	if currentTaskId then
		closeWindow()
	end
end)

playerDiedEvent.OnClientEvent:Connect(function()
	if currentTaskId then
		closeWindow()
	end
end)

localPlayer.CharacterAdded:Connect(function()
	if currentTaskId then
		closeWindow()
	end
end)
