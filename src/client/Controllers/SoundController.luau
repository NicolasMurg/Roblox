--!strict
-- SoundController: plays UI / Jumpscare / Ambience through the SoundGroups
-- declared in SoundService. Spatial sounds are parented to world parts so
-- Roblox's built-in falloff does the work.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local SoundController = Knit.CreateController({
	Name = "SoundController",
})

function SoundController:PlayUI(soundId: string)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.SoundGroup = SoundService:FindFirstChild("UI") :: SoundGroup
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function() sound:Destroy() end)
end

function SoundController:PlaySpatial(soundId: string, parent: Instance, volume: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 1
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.SoundGroup = SoundService:FindFirstChild("SFX") :: SoundGroup
	sound.Parent = parent
	sound:Play()
	sound.Ended:Once(function() sound:Destroy() end)
end

function SoundController:KnitStart() end

return SoundController
