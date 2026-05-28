--!strict
-- InputController: central keybind registry. Other controllers subscribe to
-- semantic actions ("Sprint", "Interact", "ToggleFlashlight") instead of
-- binding to raw KeyCodes themselves — makes rebinding a single-file change.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)

local InputController = Knit.CreateController({
	Name = "InputController",

	-- Default bindings. TODO: load from profile for rebind support.
	_bindings = {
		Sprint = Enum.KeyCode.LeftShift,
		Crouch = Enum.KeyCode.LeftControl,
		Interact = Enum.KeyCode.E,
		ToggleFlashlight = Enum.KeyCode.F,
		OpenInventory = Enum.KeyCode.Tab,
		OpenCrafting = Enum.KeyCode.C,
	},

	ActionPressed = Signal.new() :: any,
	ActionReleased = Signal.new() :: any,
})

function InputController:KnitInit() end

function InputController:KnitStart()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		for action, key in self._bindings do
			if input.KeyCode == key then
				self.ActionPressed:Fire(action)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		for action, key in self._bindings do
			if input.KeyCode == key then
				self.ActionReleased:Fire(action)
			end
		end
	end)
end

return InputController
