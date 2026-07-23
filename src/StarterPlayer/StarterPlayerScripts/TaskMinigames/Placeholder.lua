--[[
	==========================================================================
	PLACEHOLDER MINIGAME
	This ONE module currently stands in for EVERY real task minigame. Every
	task def points its `module` field at "Placeholder" until its real minigame
	is built - at which point that minigame gets its own ModuleScript in this
	folder and the def is repointed. Do not build gameplay on top of this; it
	exists only so the whole task pipeline (open -> play -> finish -> validate)
	works end to end before any real minigame exists.
	==========================================================================

	Minigame contract (every minigame in this folder implements this):

	    Build(contentFrame, config, onComplete) -> cleanup

	  - contentFrame: a Frame the minigame owns and builds its UI inside.
	  - config:       the def.config table for this task (tuning values).
	  - onComplete:   call EXACTLY once, when the player succeeds. TaskRunner
	                  reports it to the server; the server has the final say.
	  - returns:      a cleanup function that MUST fully undo everything the
	                  minigame created/connected (destroy instances, disconnect
	                  events) so the window can be reused for the next task.
]]

local RunService = game:GetService("RunService")

local Placeholder = {}

-- How long the button must be held (seconds) for the placeholder to "succeed".
local FILL_TIME = 1.5

function Placeholder.Build(contentFrame, _config, onComplete)
	local connections = {}
	local instances = {}

	local function track(instance)
		table.insert(instances, instance)
		return instance
	end

	-- ---- UI ----
	local instruction = track(Instance.new("TextLabel"))
	instruction.Size = UDim2.new(1, -20, 0, 40)
	instruction.Position = UDim2.new(0, 10, 0, 20)
	instruction.BackgroundTransparency = 1
	instruction.TextColor3 = Color3.new(1, 1, 1)
	instruction.TextScaled = true
	instruction.Font = Enum.Font.Gotham
	instruction.Text = "Hold the button to complete (placeholder)"
	instruction.Parent = contentFrame

	local barBg = track(Instance.new("Frame"))
	barBg.Size = UDim2.new(1, -40, 0, 24)
	barBg.Position = UDim2.new(0, 20, 0, 80)
	barBg.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	barBg.Parent = contentFrame

	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.new(0, 0, 1, 0)
	barFill.BackgroundColor3 = Color3.fromRGB(120, 220, 120)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg -- destroyed with barBg, no need to track separately

	local holdButton = track(Instance.new("TextButton"))
	holdButton.Size = UDim2.new(0, 200, 0, 90)
	holdButton.Position = UDim2.new(0.5, -100, 0, 130)
	holdButton.BackgroundColor3 = Color3.fromRGB(70, 70, 90)
	holdButton.TextColor3 = Color3.new(1, 1, 1)
	holdButton.TextScaled = true
	holdButton.Font = Enum.Font.GothamBold
	holdButton.Text = "HOLD"
	holdButton.Parent = contentFrame

	-- ---- Fill logic ----
	local holding = false
	local progress = 0
	local completed = false

	local function updateBar()
		barFill.Size = UDim2.new(progress, 0, 1, 0)
	end

	local function stopHolding()
		-- Releasing early resets the fill.
		if completed then
			return
		end
		holding = false
		progress = 0
		updateBar()
	end

	table.insert(connections, holdButton.MouseButton1Down:Connect(function()
		if completed then
			return
		end
		holding = true
	end))
	table.insert(connections, holdButton.MouseButton1Up:Connect(stopHolding))
	table.insert(connections, holdButton.MouseLeave:Connect(stopHolding))

	table.insert(connections, RunService.RenderStepped:Connect(function(dt)
		if completed or not holding then
			return
		end
		progress = math.min(1, progress + dt / FILL_TIME)
		updateBar()
		if progress >= 1 then
			completed = true
			onComplete()
		end
	end))

	-- ---- Cleanup ----
	return function()
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		for _, instance in ipairs(instances) do
			instance:Destroy()
		end
	end
end

return Placeholder
