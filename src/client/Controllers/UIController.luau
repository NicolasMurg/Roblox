--!strict
-- UIController: root of all player-facing UI. Spawns/manages ScreenGuis and
-- brokers between other controllers and UI components.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local StaminaBar = require(script.Parent.Parent.UI.StaminaBar)

local UIController = Knit.CreateController({
	Name = "UIController",
})

function UIController:KnitInit() end

function UIController:KnitStart()
	-- TODO: mount lobby menus (crafting, trading, shop)
	-- TODO: subscribe to DataService.ProfileUpdated -> refresh inventory UI
	self._dataService = Knit.GetService("DataService")

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local bar = StaminaBar.new(playerGui)
	self._staminaBar = bar

	local movementController = Knit.GetController("MovementController")
	bar:SetStamina(movementController.Stamina)
	movementController.StaminaChanged:Connect(function(value: number)
		bar:SetStamina(value)
	end)
end

return UIController
