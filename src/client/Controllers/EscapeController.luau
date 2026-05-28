--!strict
-- EscapeController: the grabbed-victim escape minigame.
--
-- When the server fires the "EscapeMinigame" RemoteEvent with `true`, a red
-- bar appears at the bottom of THIS player's screen with 5 white markers and
-- a gray rectangle sliding back and forth. Tapping Space while the slider
-- overlaps a marker clears that marker. Clear all 5 and the client fires
-- "EscapeEscaped" to the server, which forces the Hollow to drop the victim.
--
-- The server fires the event with `false` to tear the UI down (victim died,
-- was released by other means, etc.). Pure local UI — only the grabbed
-- player ever sees it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local EscapeController = Knit.CreateController({
	Name = "EscapeController",
})

local MARKER_COUNT = 5
local MARKER_POSITIONS = { 0.2, 0.35, 0.5, 0.65, 0.8 } -- scale along the bar
local SLIDER_WIDTH_SCALE = 0.06
local MARKER_WIDTH_SCALE = 0.02
local SLIDER_SPEED = 0.7 -- higher = faster sweep
-- Each grab gives the victim exactly this many Space presses to clear all 5
-- markers. Every press counts — hit or miss. Run out before clearing them
-- all and the victim is locked in for good (until death / other release).
-- Resets on every startMinigame, which fires on every fresh grab.
local PRESS_BUDGET = 10

type Session = {
	gui: ScreenGui,
	slider: Frame,
	markers: { Frame },
	sliderConn: RBXScriptConnection,
	inputConn: RBXScriptConnection,
}

local function buildUI(parent: Instance): (ScreenGui, Frame, { Frame })
	local gui = Instance.new("ScreenGui")
	gui.Name = "EscapeMinigameUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = parent

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -40)
	bar.Size = UDim2.new(0.6, 0, 0, 50)
	bar.BackgroundColor3 = Color3.fromRGB(170, 30, 30)
	bar.BorderSizePixel = 0
	bar.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = bar

	local label = Instance.new("TextLabel")
	label.Name = "Instruction"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.new(0.5, 0, 0, -6)
	label.Size = UDim2.new(1, 0, 0, 24)
	label.BackgroundTransparency = 1
	label.Text = string.format("Press SPACE to break free! (%d left)", PRESS_BUDGET)
	label.TextColor3 = Color3.fromRGB(255, 245, 230)
	label.TextStrokeTransparency = 0.4
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.Parent = bar

	-- White markers at fixed positions along the bar.
	local markers: { Frame } = {}
	for i = 1, MARKER_COUNT do
		local m = Instance.new("Frame")
		m.Name = "Marker" .. i
		m.AnchorPoint = Vector2.new(0.5, 0.5)
		m.Position = UDim2.new(MARKER_POSITIONS[i], 0, 0.5, 0)
		m.Size = UDim2.new(MARKER_WIDTH_SCALE, 0, 1, -10)
		m.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		m.BorderSizePixel = 0
		m.ZIndex = 2
		m.Parent = bar
		markers[i] = m
	end

	-- Gray slider, anchored on its left edge so Position.X.Scale is its
	-- left bound directly.
	local slider = Instance.new("Frame")
	slider.Name = "Slider"
	slider.AnchorPoint = Vector2.new(0, 0.5)
	slider.Position = UDim2.new(0, 0, 0.5, 0)
	slider.Size = UDim2.new(SLIDER_WIDTH_SCALE, 0, 1, -6)
	slider.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
	slider.BackgroundTransparency = 0.15
	slider.BorderSizePixel = 0
	slider.ZIndex = 3
	slider.Parent = bar

	return gui, slider, markers, label
end

function EscapeController:KnitStart()
	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local startStopEvent = remotes:WaitForChild("EscapeMinigame") :: RemoteEvent
	local escapedEvent = remotes:WaitForChild("EscapeEscaped") :: RemoteEvent

	local session: Session? = nil

	local function stopMinigame()
		if not session then
			return
		end
		session.sliderConn:Disconnect()
		session.inputConn:Disconnect()
		session.gui:Destroy()
		session = nil
	end

	local function startMinigame()
		stopMinigame() -- never stack two sessions

		local gui, slider, markers, label = buildUI(playerGui)
		local remaining = MARKER_COUNT
		local pressesLeft = PRESS_BUDGET

		-- Slide the gray rectangle back and forth: a 0→1→0 triangle wave so
		-- it bounces between the bar's edges.
		local sliderConn = RunService.RenderStepped:Connect(function()
			local phase = (os.clock() * SLIDER_SPEED) % 2
			local p = if phase < 1 then phase else 2 - phase
			slider.Position = UDim2.new(p * (1 - SLIDER_WIDTH_SCALE), 0, 0.5, 0)
		end)

		local inputConn = UserInputService.InputBegan:Connect(function(input, processed)
			if processed or input.KeyCode ~= Enum.KeyCode.Space then
				return
			end
			if not session then
				return
			end
			-- Out of presses: the victim already burned their 10 attempts
			-- without clearing the bar. They are locked in — ignore further
			-- input until the server tears the minigame down.
			if pressesLeft <= 0 then
				return
			end

			-- Every press counts, hit or miss.
			pressesLeft -= 1

			-- Slider + marker bounds in the bar's scale space. The marker is
			-- centre-anchored (AnchorPoint.X = 0.5), so it spans half its width
			-- either side of its Position.X.Scale.
			local sliderLeft = slider.Position.X.Scale
			local sliderRight = sliderLeft + SLIDER_WIDTH_SCALE
			local halfMarker = MARKER_WIDTH_SCALE / 2

			-- Clear one marker the slider is touching. Two intervals overlap
			-- when each begins before the other ends — that's true for ANY
			-- contact, partial or complete, not just when the marker's centre
			-- is under the slider. break after one so a single press only ever
			-- removes a single marker.
			for _, marker in markers do
				if marker.Parent == nil then
					continue -- already cleared
				end
				local center = marker.Position.X.Scale
				local markerLeft = center - halfMarker
				local markerRight = center + halfMarker
				if sliderLeft <= markerRight and markerLeft <= sliderRight then
					marker:Destroy()
					remaining -= 1
					break
				end
			end

			if remaining <= 0 then
				-- Cleared every marker — break free.
				escapedEvent:FireServer()
				stopMinigame()
			elseif pressesLeft <= 0 then
				-- Budget spent with markers remaining — escape failed.
				label.Text = "You can't break free!"
				label.TextColor3 = Color3.fromRGB(120, 120, 120)
			else
				label.Text = string.format("Press SPACE to break free! (%d left)", pressesLeft)
			end
		end)

		session = {
			gui = gui,
			slider = slider,
			markers = markers,
			sliderConn = sliderConn,
			inputConn = inputConn,
		}
	end

	startStopEvent.OnClientEvent:Connect(function(active: boolean)
		if active then
			startMinigame()
		else
			stopMinigame()
		end
	end)
end

return EscapeController
