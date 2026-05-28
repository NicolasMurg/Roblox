--!strict
-- TunnelVisionController: below 50% HP the local player's vision starts to
-- close in with a black vignette that worsens as health approaches 0%.
--
-- Pure client-side and pure UI — no image assets. The vignette is two
-- overlaid black frames, one with a left↔right gradient and one with a
-- top↔bottom gradient. Each gradient is transparent (clear) in the middle
-- and opaque (black) at the edges; as the effect intensifies the clear
-- window shrinks and the edges darken, so the visible area tunnels down to
-- a small central patch. Intensity is eased each frame so health changes
-- (damage spikes, regen) fade in/out smoothly rather than snapping.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local TunnelVisionController = Knit.CreateController({
	Name = "TunnelVisionController",
})

-- The effect only exists below this health fraction; 0.5 = 50% HP.
local START_FRACTION = 0.5
-- Clear-window half-width along each axis (scale): wide at intensity 0,
-- tiny at intensity 1 → the tunnel closes in.
local CLEAR_HALF_MAX = 0.45
local CLEAR_HALF_MIN = 0.06
-- Edge transparency: mostly see-through at intensity 0, fully black at 1.
local EDGE_TRANSP_MIN = 0.85 -- at intensity 0 (just crossed 50%)
local EDGE_TRANSP_MAX = 0.0 -- at intensity 1 (near death)
-- Easing rate for the intensity lerp (higher = snappier).
local EASE_RATE = 6
-- Saturation at full intensity. ColorCorrectionEffect.Saturation = -1 is
-- fully greyscale, 0 is normal, so we lerp 0 → SATURATION_MIN as HP falls.
local SATURATION_MIN = -1

local function buildVignette(parent: Instance): (ScreenGui, UIGradient, UIGradient)
	local gui = Instance.new("ScreenGui")
	gui.Name = "TunnelVisionUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Below the escape minigame (DisplayOrder 50) so the struggle bar stays
	-- legible through the darkness.
	gui.DisplayOrder = 10
	gui.Enabled = false
	gui.Parent = parent

	local function newAxisFrame(name: string, rotation: number): UIGradient
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BackgroundTransparency = 0 -- gradient drives the actual fade
		frame.BorderSizePixel = 0
		frame.Parent = gui
		local grad = Instance.new("UIGradient")
		grad.Rotation = rotation
		grad.Parent = frame
		return grad
	end

	local hGrad = newAxisFrame("Horizontal", 0) -- darkens left/right
	local vGrad = newAxisFrame("Vertical", 90) -- darkens top/bottom
	return gui, hGrad, vGrad
end

local function intensityToSequence(intensity: number): NumberSequence
	local clearHalf = CLEAR_HALF_MAX + (CLEAR_HALF_MIN - CLEAR_HALF_MAX) * intensity
	local edgeTransp = EDGE_TRANSP_MIN + (EDGE_TRANSP_MAX - EDGE_TRANSP_MIN) * intensity
	-- Edges opaque-ish, center fully clear. Keypoints strictly increasing.
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, edgeTransp),
		NumberSequenceKeypoint.new(0.5 - clearHalf, 1),
		NumberSequenceKeypoint.new(0.5 + clearHalf, 1),
		NumberSequenceKeypoint.new(1, edgeTransp),
	})
end

function TunnelVisionController:KnitStart()
	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local gui, hGrad, vGrad = buildVignette(playerGui)

	-- Greyscale shift. A local ColorCorrectionEffect (client-side, so only
	-- this player's screen) whose Saturation we drag toward -1 as the victim
	-- nears death.
	local colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "TunnelVisionDesaturate"
	colorCorrection.Saturation = 0
	colorCorrection.Enabled = false
	colorCorrection.Parent = Lighting

	-- Current bound Humanoid, swapped on respawn.
	local humanoid: Humanoid? = nil
	local function bindCharacter(char: Model)
		humanoid = char:WaitForChild("Humanoid") :: Humanoid
	end
	if localPlayer.Character then
		bindCharacter(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(bindCharacter)

	local current = 0
	RunService.RenderStepped:Connect(function(dt)
		-- Target intensity: 0 at/above 50% HP, ramps to 1 at 0% HP.
		local target = 0
		local hum = humanoid
		if hum and hum.Health > 0 and hum.MaxHealth > 0 then
			local frac = hum.Health / hum.MaxHealth
			if frac < START_FRACTION then
				target = (START_FRACTION - frac) / START_FRACTION
			end
		end

		current += (target - current) * math.min(1, dt * EASE_RATE)

		if current < 0.01 then
			gui.Enabled = false
			colorCorrection.Enabled = false
		else
			gui.Enabled = true
			local clamped = math.clamp(current, 0, 1)
			local seq = intensityToSequence(clamped)
			hGrad.Transparency = seq
			vGrad.Transparency = seq
			colorCorrection.Enabled = true
			colorCorrection.Saturation = SATURATION_MIN * clamped
		end
	end)
end

return TunnelVisionController
