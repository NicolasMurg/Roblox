--!strict
-- StaminaBar: bottom-center HUD bar whose fill width and hue track sprint stamina.

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Modules.GameConfig)

local MAX_STAMINA = GameConfig.Movement.SprintStaminaMax
local BAR_WIDTH = 300
local BAR_HEIGHT = 14

local FULL_COLOR = Color3.fromRGB(170, 255, 220)
local EMPTY_COLOR = Color3.fromRGB(170, 25, 30)

local FILL_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FADE_TWEEN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local StaminaBar = {}
StaminaBar.__index = StaminaBar

export type StaminaBar = typeof(setmetatable(
	{} :: {
		_gui: ScreenGui,
		_outer: Frame,
		_fill: Frame,
		_fillTween: Tween?,
		_outerFade: Tween?,
		_fillFade: Tween?,
		_hidden: boolean,
	},
	StaminaBar
))

function StaminaBar.new(parent: Instance): StaminaBar
	local gui = Instance.new("ScreenGui")
	gui.Name = "StaminaHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local outer = Instance.new("Frame")
	outer.Name = "Outer"
	outer.AnchorPoint = Vector2.new(0.5, 1)
	outer.Position = UDim2.fromScale(0.5, 0.95)
	outer.Size = UDim2.fromOffset(BAR_WIDTH, BAR_HEIGHT)
	outer.BackgroundColor3 = Color3.fromRGB(12, 10, 14)
	outer.BackgroundTransparency = 0.25
	outer.BorderSizePixel = 0
	outer.Parent = gui

	local outerStroke = Instance.new("UIStroke")
	outerStroke.Thickness = 1
	outerStroke.Color = Color3.fromRGB(40, 35, 45)
	outerStroke.Transparency = 0.2
	outerStroke.Parent = outer

	local outerCorner = Instance.new("UICorner")
	outerCorner.CornerRadius = UDim.new(0, 4)
	outerCorner.Parent = outer

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.AnchorPoint = Vector2.new(0, 0.5)
	fill.Position = UDim2.new(0, 2, 0.5, 0)
	fill.Size = UDim2.new(1, -4, 1, -4)
	fill.BackgroundColor3 = FULL_COLOR
	fill.BackgroundTransparency = 0
	fill.BorderSizePixel = 0
	fill.Parent = outer

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = fill

	gui.Parent = parent

	local self = setmetatable({
		_gui = gui,
		_outer = outer,
		_fill = fill,
		_fillTween = nil,
		_outerFade = nil,
		_fillFade = nil,
		_hidden = false,
	}, StaminaBar)

	self:SetStamina(MAX_STAMINA)
	return self
end

function StaminaBar.SetStamina(self: StaminaBar, value: number)
	local clamped = math.clamp(value, 0, MAX_STAMINA)
	local ratio = clamped / MAX_STAMINA

	if self._fillTween then
		self._fillTween:Cancel()
	end
	self._fillTween = TweenService:Create(self._fill, FILL_TWEEN, {
		Size = UDim2.new(ratio, -4, 1, -4),
		BackgroundColor3 = EMPTY_COLOR:Lerp(FULL_COLOR, ratio),
	})
	;(self._fillTween :: Tween):Play()

	local shouldHide = clamped >= MAX_STAMINA
	if shouldHide ~= self._hidden then
		self._hidden = shouldHide
		self:_setVisible(not shouldHide)
	end
end

function StaminaBar._setVisible(self: StaminaBar, visible: boolean)
	if self._outerFade then
		self._outerFade:Cancel()
	end
	if self._fillFade then
		self._fillFade:Cancel()
	end

	local outerTarget = if visible then 0.25 else 1
	local fillTarget = if visible then 0 else 1

	self._outerFade = TweenService:Create(self._outer, FADE_TWEEN, {
		BackgroundTransparency = outerTarget,
	})
	self._fillFade = TweenService:Create(self._fill, FADE_TWEEN, {
		BackgroundTransparency = fillTarget,
	})
	;(self._outerFade :: Tween):Play()
	;(self._fillFade :: Tween):Play()
end

function StaminaBar.Destroy(self: StaminaBar)
	if self._fillTween then
		self._fillTween:Cancel()
	end
	if self._outerFade then
		self._outerFade:Cancel()
	end
	if self._fillFade then
		self._fillFade:Cancel()
	end
	self._gui:Destroy()
end

return StaminaBar
