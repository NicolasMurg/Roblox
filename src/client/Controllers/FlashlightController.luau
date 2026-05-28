--!strict
-- FlashlightController: local flashlight toggle + battery + ghost-proximity flicker.
-- The actual SpotLight lives on the equipped Tool. This controller just orchestrates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local GameConfig = require(ReplicatedStorage.Shared.Modules.GameConfig)

local FlashlightController = Knit.CreateController({
	Name = "FlashlightController",

	_on = false,
	_battery = GameConfig.Flashlight.DefaultBatteryMax,
	_light = nil :: SpotLight?,
})

function FlashlightController:Toggle()
	self._on = not self._on
	if self._light then
		self._light.Enabled = self._on and self._battery > 0
	end
end

function FlashlightController:Flicker(durationSeconds: number)
	if not self._light then return end
	local light = self._light
	task.spawn(function()
		local t = 0
		while t < durationSeconds do
			light.Enabled = math.random() > 0.5
			local step = 0.04 + math.random() * 0.08
			task.wait(step)
			t += step
		end
		light.Enabled = self._on and self._battery > 0
	end)
end

function FlashlightController:KnitStart()
	local inputController = Knit.GetController("InputController")
	inputController.ActionPressed:Connect(function(action: string)
		if action == "ToggleFlashlight" then
			self:Toggle()
		end
	end)

	-- Drain battery while on.
	RunService.Heartbeat:Connect(function(dt)
		if self._on and self._battery > 0 then
			self._battery = math.max(0, self._battery - GameConfig.Flashlight.DefaultBatteryDrainPerSecond * dt)
			if self._battery == 0 and self._light then
				self._light.Enabled = false
			end
		end
	end)
end

return FlashlightController
