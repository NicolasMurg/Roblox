--!strict
-- PossessionController: shows a "Become The Hollow" button to the authorized
-- player only. Clicking it fires a RemoteEvent that asks the server to toggle
-- their possession state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local AUTHORIZED_USERNAME = "Mlg6423"
local REMOTE_NAME = "TogglePossession"
local REMOTE_NAME_GRAB = "ToggleGrab"

local PossessionController = Knit.CreateController({
	Name = "PossessionController",
})

local function buildButton(parent: Instance): TextButton
	local gui = Instance.new("ScreenGui")
	gui.Name = "PossessionUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parent

	local button = Instance.new("TextButton")
	button.Name = "PossessButton"
	button.Size = UDim2.fromOffset(240, 56)
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, -20, 0, 20)
	button.BackgroundColor3 = Color3.fromRGB(30, 25, 35)
	button.BackgroundTransparency = 0.1
	button.BorderSizePixel = 0
	button.TextColor3 = Color3.fromRGB(255, 245, 230)
	button.Text = "Become The Hollow"
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.AutoButtonColor = true
	button.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(180, 50, 50)
	stroke.Thickness = 2
	stroke.Transparency = 0.2
	stroke.Parent = button

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	return button
end

function PossessionController:KnitStart()
	local localPlayer = Players.LocalPlayer
	if localPlayer.Name ~= AUTHORIZED_USERNAME then
		return
	end

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local toggleEvent = remotes:WaitForChild(REMOTE_NAME) :: RemoteEvent
	print("[Possession] Client found RemoteEvent:", toggleEvent:GetFullName())

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local button = buildButton(playerGui)

	-- Optimistic local toggle for the label. Server is authoritative for the
	-- actual visual swap — if it ever drifts we can add a confirm event back.
	local localPossessed = false
	button.MouseButton1Click:Connect(function()
		print("[Possession] Button clicked — firing toggle event")
		toggleEvent:FireServer()
		localPossessed = not localPossessed
		button.Text = if localPossessed then "Return to Human" else "Become The Hollow"
	end)

	-- Key 1 = toggle hold-by-head grab (server validates possession + range).
	local grabEvent = remotes:WaitForChild(REMOTE_NAME_GRAB) :: RemoteEvent
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.One then
			print("[Possession] Key 1 pressed — firing grab event")
			grabEvent:FireServer()
		end
	end)
end

return PossessionController
