--[[
	ClientSettings.lua  (ModuleScript)
	The single source of truth for client-side settings: keybinds, master volume,
	and the reduce-effects accessibility flag. Required by SettingsUI (which edits
	them) and, from the next prompt on, by every consumer that reads them.

	SESSION-ONLY BY DESIGN: nothing here persists. Settings reset on rejoin.
	DataStore persistence is a later phase - when it lands it loads into this same
	state on require and saves on change; the public API below stays the same.

	Change signalling: any setter fires Changed with the setting's name so open UI
	rows (and future consumers) can refresh live. ResetLayout is a separate signal
	that windows subscribe to so "Reset UI layout" can move them home.
]]

local ClientSettings = {}

-- Remappable actions, in the order the settings UI lists them.
ClientSettings.KeybindOrder = {
	"Kill",
	"Store",
	"Inventory",
	"Sabotage",
	"Powerup1",
	"Powerup2",
	"SpectatePrev",
	"SpectateNext",
	"TaskAction",
}

local DEFAULT_KEYS = {
	Kill = Enum.KeyCode.F,
	Store = Enum.KeyCode.G,
	Inventory = Enum.KeyCode.L,
	Sabotage = Enum.KeyCode.C,
	Powerup1 = Enum.KeyCode.One,
	Powerup2 = Enum.KeyCode.Two,
	SpectatePrev = Enum.KeyCode.Q,
	SpectateNext = Enum.KeyCode.E,
	TaskAction = Enum.KeyCode.F,
}

ClientSettings.DisplayNames = {
	Kill = "Kill",
	Store = "Open Store",
	Inventory = "Open Inventory",
	Sabotage = "Sabotage panel",
	Powerup1 = "Powerup slot 1",
	Powerup2 = "Powerup slot 2",
	SpectatePrev = "Spectate previous",
	SpectateNext = "Spectate next",
	TaskAction = "Task action",
}

-- Movement keys, plus E: E is the world-interact key baked into ProximityPrompts,
-- a shared SERVER property (ProximityPrompt.KeyboardKeyCode) that cannot be
-- remapped per-player without rebuilding the prompt system. So none of these can
-- be bound to a remappable action.
local RESERVED = {
	[Enum.KeyCode.W] = true,
	[Enum.KeyCode.A] = true,
	[Enum.KeyCode.S] = true,
	[Enum.KeyCode.D] = true,
	[Enum.KeyCode.Space] = true,
	[Enum.KeyCode.E] = true,
}
ClientSettings.RESERVED = RESERVED

-- ---- Live session state (defaults; reset on rejoin) ----
local keys = table.clone(DEFAULT_KEYS)
local volume = 1
local reduceEffects = false

-- Fired with (settingName) on any change: an action name for a keybind, or
-- "Volume" / "ReduceEffects".
ClientSettings.Changed = Instance.new("BindableEvent")
-- Consumers (movable windows) subscribe to this; FireResetLayout pulses it.
ClientSettings.ResetLayout = Instance.new("BindableEvent")

-- ============================================================
-- Keybinds
-- ============================================================
function ClientSettings.GetKey(action)
	return keys[action]
end

-- Rejects a RESERVED key ("Reserved") and a key already bound to a DIFFERENT
-- remappable action ("InUse"). Duplicate detection spans only the remappable
-- actions in `keys`, so two actions can never share a key going forward.
function ClientSettings.SetKey(action, keyCode)
	if RESERVED[keyCode] then
		return false, "Reserved"
	end
	for otherAction, boundKey in pairs(keys) do
		if otherAction ~= action and boundKey == keyCode then
			return false, "InUse"
		end
	end
	keys[action] = keyCode
	ClientSettings.Changed:Fire(action)
	return true
end

-- ============================================================
-- Master volume (0..1)
-- ============================================================
function ClientSettings.GetVolume()
	return volume
end

function ClientSettings.SetVolume(v)
	volume = math.clamp(v, 0, 1)
	ClientSettings.Changed:Fire("Volume")
end

-- Helper for sound sites: scale a base volume by the master setting.
function ClientSettings.ApplyVolume(base)
	return base * volume
end

-- ============================================================
-- Reduce screen effects (accessibility)
-- ============================================================
function ClientSettings.GetReduceEffects()
	return reduceEffects
end

function ClientSettings.SetReduceEffects(state)
	reduceEffects = state and true or false
	ClientSettings.Changed:Fire("ReduceEffects")
end

-- ============================================================
-- UI layout reset
-- ============================================================
function ClientSettings.FireResetLayout()
	ClientSettings.ResetLayout:Fire()
end

return ClientSettings
