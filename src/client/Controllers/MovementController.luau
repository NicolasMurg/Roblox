--!strict
-- MovementController: forwards input intent to MovementService and caches
-- the latest stamina value for the HUD.
--
-- Zero client-side authority on speed. The server decides what the character's
-- WalkSpeed actually becomes. This controller exists to translate semantic
-- actions (from InputController) into server calls, and to expose stamina
-- to UIController for the bar.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)

local GameConfig = require(ReplicatedStorage.Shared.Modules.GameConfig)

local MovementController = Knit.CreateController({
	Name = "MovementController",

	Stamina = GameConfig.Movement.SprintStaminaMax,
	StaminaChanged = Signal.new() :: any,

	_sprintHeld = false,
	_crouchHeld = false,
})

function MovementController:GetStamina(): number
	return self.Stamina
end

function MovementController:KnitInit() end

function MovementController:KnitStart()
	local input = Knit.GetController("InputController")
	local movement = Knit.GetService("MovementService")

	input.ActionPressed:Connect(function(action: string)
		if action == "Sprint" then
			self._sprintHeld = true
			movement:SetSprinting(true)
		elseif action == "Crouch" then
			self._crouchHeld = true
			movement:SetCrouching(true)
		end
	end)

	input.ActionReleased:Connect(function(action: string)
		if action == "Sprint" then
			self._sprintHeld = false
			movement:SetSprinting(false)
		elseif action == "Crouch" then
			self._crouchHeld = false
			movement:SetCrouching(false)
		end
	end)

	movement.StaminaChanged:Connect(function(stamina: number)
		self.Stamina = stamina
		self.StaminaChanged:Fire(stamina)
	end)
end

return MovementController
