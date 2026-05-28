--!strict
-- CameraController: owns FOV changes (sprinting, jumpscare warp) and screen
-- shake. Other controllers ask this controller for effects instead of touching
-- Camera directly — keeps effects composable (e.g., jumpscare overrides shake).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage.Packages.Knit)

local CameraController = Knit.CreateController({
	Name = "CameraController",

	_baseFov = 70,
	_fovOffset = 0,
	_shakeAmplitude = 0,
	_shakeDecay = 0,
})

function CameraController:SetFovOffset(offset: number)
	self._fovOffset = offset
end

function CameraController:Shake(amplitude: number, decayPerSecond: number)
	self._shakeAmplitude = math.max(self._shakeAmplitude, amplitude)
	self._shakeDecay = decayPerSecond
end

function CameraController:KnitStart()
	local cam = Workspace.CurrentCamera
	self._baseFov = cam.FieldOfView

	RunService.RenderStepped:Connect(function(dt)
		cam.FieldOfView = self._baseFov + self._fovOffset

		if self._shakeAmplitude > 0 then
			local a = self._shakeAmplitude
			local offset = Vector3.new(
				(math.random() - 0.5) * 2 * a,
				(math.random() - 0.5) * 2 * a,
				(math.random() - 0.5) * 2 * a
			)
			cam.CFrame = cam.CFrame + offset
			self._shakeAmplitude = math.max(0, self._shakeAmplitude - self._shakeDecay * dt)
		end
	end)
end

return CameraController
