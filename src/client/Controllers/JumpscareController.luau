--!strict
-- JumpscareController: the signature horror moment. Driven entirely client-side
-- for zero latency. Server fires GhostService.Client.Jumpscare:Fire(player) and
-- this controller handles the rest — screen flash, FOV warp, shake, static audio,
-- distorted face overlay, then a fade-out.
--
-- The server is responsible for deciding when to jumpscare; this controller
-- only renders it. After the sequence completes, server will have teleported
-- the player back to lobby.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local JumpscareController = Knit.CreateController({
	Name = "JumpscareController",
	_playing = false,
})

local LOCAL_PLAYER = Players.LocalPlayer

local function buildOverlay(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "JumpscareOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10_000
	gui.Enabled = false

	local black = Instance.new("Frame")
	black.Name = "Blackout"
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BackgroundTransparency = 1
	black.BorderSizePixel = 0
	black.ZIndex = 1
	black.Parent = gui

	local face = Instance.new("ImageLabel")
	face.Name = "Face"
	face.Size = UDim2.fromScale(1, 1)
	face.AnchorPoint = Vector2.new(0.5, 0.5)
	face.Position = UDim2.fromScale(0.5, 0.5)
	face.BackgroundTransparency = 1
	face.ImageTransparency = 1
	face.ScaleType = Enum.ScaleType.Crop
	-- TODO: replace placeholder with an actual distorted-face decal.
	-- Use a rbxassetid:// when you have art ready.
	face.Image = ""
	face.ZIndex = 2
	face.Parent = gui

	local red = Instance.new("Frame")
	red.Name = "RedFlash"
	red.Size = UDim2.fromScale(1, 1)
	red.BackgroundColor3 = Color3.fromRGB(180, 0, 0)
	red.BackgroundTransparency = 1
	red.BorderSizePixel = 0
	red.ZIndex = 3
	red.Parent = gui

	return gui
end

function JumpscareController:_BuildStaticSound(): Sound
	local s = Instance.new("Sound")
	s.Name = "JumpscareStatic"
	-- TODO: swap in a real loud-static asset once uploaded.
	s.SoundId = ""
	s.Volume = 2
	s.PlaybackSpeed = 1
	s.SoundGroup = SoundService:FindFirstChild("Jumpscare") :: SoundGroup
	s.Parent = SoundService
	return s
end

function JumpscareController:Play()
	if self._playing then return end
	self._playing = true

	local cam = Knit.GetController("CameraController")

	self._overlay.Enabled = true
	local blackout = self._overlay:FindFirstChild("Blackout") :: Frame
	local face = self._overlay:FindFirstChild("Face") :: ImageLabel
	local red = self._overlay:FindFirstChild("RedFlash") :: Frame

	-- Reset transparencies
	blackout.BackgroundTransparency = 1
	face.ImageTransparency = 1
	red.BackgroundTransparency = 1

	-- Phase 1: red flash + warp FOV out
	TweenService:Create(red, TweenInfo.new(0.08), { BackgroundTransparency = 0.2 }):Play()
	cam:SetFovOffset(40)
	cam:Shake(2.5, 4)
	self._static:Play()

	task.wait(0.1)

	-- Phase 2: face slams in
	face.ImageTransparency = 0
	face.Size = UDim2.fromScale(1.5, 1.5)
	TweenService:Create(face, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(1, 1),
	}):Play()
	TweenService:Create(red, TweenInfo.new(0.3), { BackgroundTransparency = 0.6 }):Play()

	task.wait(0.9)

	-- Phase 3: blackout
	TweenService:Create(blackout, TweenInfo.new(0.5), { BackgroundTransparency = 0 }):Play()
	TweenService:Create(face, TweenInfo.new(0.5), { ImageTransparency = 1 }):Play()
	TweenService:Create(red, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
	cam:SetFovOffset(0)

	task.wait(1.2)

	self._static:Stop()

	-- Phase 4: fade back in (server should have respawned us in the lobby by now)
	TweenService:Create(blackout, TweenInfo.new(0.8), { BackgroundTransparency = 1 }):Play()
	task.wait(0.9)

	self._overlay.Enabled = false
	self._playing = false
end

function JumpscareController:KnitInit()
	local playerGui = LOCAL_PLAYER:WaitForChild("PlayerGui")
	self._overlay = buildOverlay()
	self._overlay.Parent = playerGui
	self._static = self:_BuildStaticSound()
end

function JumpscareController:KnitStart()
	local ghostService = Knit.GetService("GhostService")
	ghostService.Jumpscare:Connect(function()
		task.spawn(function()
			self:Play()
		end)
	end)
end

return JumpscareController
