--!strict
-- BreathingController: plays a looping scared-breathing sound on the local
-- player; volume scales with proximity to the active villain.
--
-- Pure client atmosphere — never touches the server. Each player hears their
-- own breathing, never anyone else's.
--
-- If the SoundId below stops working (Roblox sometimes restricts third-party
-- audio retroactively), try one of these or upload your own to the Creator
-- Store and paste the new id:
--   rbxassetid://6814463121  -- Heavy Scared Breathing
--   rbxassetid://3725917109  -- Heavy Breathing Man Sound

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Knit = require(ReplicatedStorage.Packages.Knit)

local BREATHING_SOUND_ID = "rbxassetid://6814463121"

-- Distance band, in studs. Beyond MAX -> silent; at/inside MIN -> full volume.
-- If line-of-sight to the villain is blocked by any non-villain part, the
-- effective MAX is halved (you have to be closer to start breathing).
local MIN_AUDIBLE_DISTANCE = 4
local MAX_AUDIBLE_DISTANCE = 30
local MAX_VOLUME = 2.5

-- Exponential smoothing for the obstructed/unobstructed transition. Without
-- this, stepping out from behind a wall instantly doubles the effective max,
-- which spikes the volume. Higher rate = snappier; lower = more subtle.
-- 1.5/sec gives ~63% of the transition in ~0.67s and ~95% in ~2s.
local OBSTRUCTION_SMOOTHING_RATE = 1.5

-- Pitch nudges up slightly as the player closes in (panic). 1.0 far, 1.15 near.
local PITCH_FAR = 1
local PITCH_NEAR = 1.15

local BreathingController = Knit.CreateController({
	Name = "BreathingController",
})

local function findVillain(): Model?
	local folder = Workspace:FindFirstChild("VillainPreview")
	if not folder then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child.PrimaryPart then
			return child
		end
	end
	return nil
end

-- Looks for any Sound the user dragged into Workspace (or its descendants) and
-- returns its asset id. We prefer this over the hardcoded fallback because
-- toolbox-inserted sounds are guaranteed to be licensed for this experience.
local function findToolboxBreathingId(): (string?, Sound?)
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("Sound") and descendant.SoundId ~= "" then
			return descendant.SoundId, descendant
		end
	end
	return nil, nil
end

function BreathingController:KnitStart()
	local toolboxId, toolboxSound = findToolboxBreathingId()
	local soundIdToUse = toolboxId or BREATHING_SOUND_ID
	if toolboxId then
		print("[Breathing] Using toolbox-inserted sound:", toolboxId)
		-- Silence the original so we don't get two breathings layered.
		toolboxSound:Stop()
		toolboxSound.Volume = 0
		toolboxSound.Playing = false
	else
		print("[Breathing] No toolbox sound found in Workspace; falling back to", BREATHING_SOUND_ID)
	end

	local sound = Instance.new("Sound")
	sound.Name = "ScaredBreathing"
	sound.SoundId = soundIdToUse
	sound.Looped = true
	sound.Volume = 0
	sound.PlaybackSpeed = PITCH_FAR
	local sfxGroup = SoundService:FindFirstChild("SFX")
	if sfxGroup and sfxGroup:IsA("SoundGroup") then
		sound.SoundGroup = sfxGroup
	end
	sound.Parent = SoundService

	-- Diagnostics: log whether the audio actually loaded. TimeLength==0 after
	-- ~3 seconds almost always means Roblox refused the asset (restricted,
	-- removed, or not licensed for this experience).
	sound.Loaded:Connect(function()
		print("[Breathing] Sound loaded — TimeLength:", sound.TimeLength)
	end)
	task.delay(3, function()
		if sound.TimeLength == 0 then
			warn("[Breathing] Sound did NOT load after 3s. The asset id is likely restricted. "
				.. "Replace BREATHING_SOUND_ID with one you uploaded or one from the Studio Toolbox.")
		end
	end)

	sound:Play()

	local lastLog = 0
	local smoothedMax = MAX_AUDIBLE_DISTANCE
	RunService.Heartbeat:Connect(function(dt)
		local player = Players.LocalPlayer
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			sound.Volume = 0
			return
		end
		local villain = findVillain()
		local villainRoot = villain and villain.PrimaryPart
		if not villainRoot then
			sound.Volume = 0
			return
		end

		local distance = (hrp.Position - villainRoot.Position).Magnitude

		-- Line-of-sight check. Cast from the player to the villain, excluding
		-- the villain rig and the player's own character. Any hit means a wall
		-- or prop is in the way, so we halve the effective max distance.
		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.FilterDescendantsInstances = { villain, char }
		rayParams.IgnoreWater = true
		local direction = villainRoot.Position - hrp.Position
		local hit = Workspace:Raycast(hrp.Position, direction, rayParams)
		local obstructed = hit ~= nil
		local targetMax = if obstructed then MAX_AUDIBLE_DISTANCE / 2 else MAX_AUDIBLE_DISTANCE

		-- Ease the effective max toward the target so stepping out from cover
		-- doesn't instantly double the audible range (and spike the volume).
		local alpha = 1 - math.exp(-dt * OBSTRUCTION_SMOOTHING_RATE)
		smoothedMax = smoothedMax + (targetMax - smoothedMax) * alpha

		local t: number
		if distance >= smoothedMax then
			t = 0
		elseif distance <= MIN_AUDIBLE_DISTANCE then
			t = 1
		else
			t = 1 - (distance - MIN_AUDIBLE_DISTANCE) / (smoothedMax - MIN_AUDIBLE_DISTANCE)
		end
		sound.Volume = MAX_VOLUME * t
		sound.PlaybackSpeed = PITCH_FAR + (PITCH_NEAR - PITCH_FAR) * t

		-- Throttled distance/volume log so we can confirm the loop is running
		-- and what values it's producing.
		local now = os.clock()
		if now - lastLog > 1 then
			lastLog = now
			print(string.format("[Breathing] dist=%.1f max=%.1f vol=%.2f obstructed=%s loaded=%s",
				distance, smoothedMax, sound.Volume, tostring(obstructed), tostring(sound.IsLoaded)))
		end
	end)
end

return BreathingController
