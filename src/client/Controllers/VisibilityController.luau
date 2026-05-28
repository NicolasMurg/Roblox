--!strict
-- VisibilityController: per-player button that maxes out lighting AND attaches
-- a bright PointLight to the character, so the user can see models clearly
-- without being lost in the Future lighting engine's voxel shadows.
--
-- Pure client-side — only the local player's view changes, never replicates.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local LIGHT_NAME = "VisibilityLight"

local VisibilityController = Knit.CreateController({
	Name = "VisibilityController",
})

local function buildButton(parent: Instance): TextButton
	local gui = Instance.new("ScreenGui")
	gui.Name = "VisibilityUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent

	local button = Instance.new("TextButton")
	button.Name = "VisibilityButton"
	button.Size = UDim2.fromOffset(240, 56)
	button.AnchorPoint = Vector2.new(1, 0)
	-- Sits below the PossessButton (which is at y=20, height=56, so y=90 leaves a 14 px gap).
	button.Position = UDim2.new(1, -20, 0, 90)
	button.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	button.BackgroundTransparency = 0.1
	button.BorderSizePixel = 0
	button.TextColor3 = Color3.fromRGB(255, 245, 230)
	button.Text = "Light On"
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.AutoButtonColor = true
	button.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(245, 240, 200)
	stroke.Thickness = 2
	stroke.Transparency = 0.2
	stroke.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	return button
end

local function attachLight(char: Model)
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	if hrp:FindFirstChild(LIGHT_NAME) then
		return
	end
	local light = Instance.new("PointLight")
	light.Name = LIGHT_NAME
	light.Color = Color3.fromRGB(255, 250, 240)
	light.Brightness = 5
	light.Range = 60
	light.Shadows = false
	light.Parent = hrp
end

local function detachLight(char: Model?)
	if not char then
		return
	end
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local light = hrp and hrp:FindFirstChild(LIGHT_NAME)
	if light then
		light:Destroy()
	end
end

function VisibilityController:KnitStart()
	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local button = buildButton(playerGui)

	local enabled = false
	local originals: { ambient: Color3, outdoor: Color3, brightness: number, shadows: boolean }? = nil

	local function apply()
		if enabled then
			-- Capture originals the first time we toggle on so we restore to
			-- whatever the world's actual lighting is (after VillainPreview's
			-- daylight override has run).
			if not originals then
				originals = {
					ambient = Lighting.Ambient,
					outdoor = Lighting.OutdoorAmbient,
					brightness = Lighting.Brightness,
					shadows = Lighting.GlobalShadows,
				}
			end
			Lighting.Ambient = Color3.fromRGB(255, 255, 255)
			Lighting.OutdoorAmbient = Color3.fromRGB(255, 255, 255)
			Lighting.Brightness = 5
			Lighting.GlobalShadows = false
			if localPlayer.Character then
				attachLight(localPlayer.Character)
			end
			button.Text = "Light Off"
		else
			if originals then
				Lighting.Ambient = originals.ambient
				Lighting.OutdoorAmbient = originals.outdoor
				Lighting.Brightness = originals.brightness
				Lighting.GlobalShadows = originals.shadows
			end
			detachLight(localPlayer.Character)
			button.Text = "Light On"
		end
	end

	button.MouseButton1Click:Connect(function()
		enabled = not enabled
		apply()
	end)

	-- Re-apply on respawn so the light follows you back into a new character.
	localPlayer.CharacterAdded:Connect(function(char)
		if enabled then
			-- Tiny wait for HumanoidRootPart to be ready.
			task.wait(0.2)
			attachLight(char)
		end
	end)
end

return VisibilityController
