--!strict
-- Debug preview: spawns the active villain (VillainAppearances.ActiveVillainId)
-- on the baseplate with a floating name label. Delete this file when done — it
-- is not loaded by Knit (it lives outside src/server/Services).

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Appearances = require(ReplicatedStorage.Shared.Modules.VillainAppearances)

-- Defensive lobby purge. If Rojo's sync dialog didn't propagate the deletion
-- of LobbyService/LobbyBuilder, kill the ModuleScripts BEFORE Knit can load
-- them, and destroy any lobby geometry that still appears in Workspace.
do
	local serverFolder = ServerScriptService:FindFirstChild("Server")
	local servicesFolder = serverFolder and serverFolder:FindFirstChild("Services")
	if servicesFolder then
		for _, name in { "LobbyService", "LobbyBuilder" } do
			local stale = servicesFolder:FindFirstChild(name)
			if stale then
				stale:Destroy()
			end
		end
	end

	local function destroyIfLobby(child: Instance)
		if child.Name == "LobbyFolder" or child.Name == "Lobby" then
			child:Destroy()
		end
	end
	for _, child in Workspace:GetChildren() do
		destroyIfLobby(child)
	end
	Workspace.ChildAdded:Connect(destroyIfLobby)

	-- Override the LobbyService spawn-teleport: if anything teleports the player
	-- into the (now demolished) lobby, lift them back onto the baseplate.
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char)
			task.wait(0.3)
			local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp and hrp.Position.Y > 6 then
				hrp.CFrame = CFrame.new(0, 5, 0)
			end
		end)
	end)
end

-- Brighten the world so the preview rigs are clearly visible. Overrides the
-- spooky defaults from default.project.json.
Lighting.ClockTime = 12
Lighting.Brightness = 3
Lighting.Ambient = Color3.fromRGB(140, 140, 145)
Lighting.OutdoorAmbient = Color3.fromRGB(160, 160, 165)
Lighting.FogStart = 5000
Lighting.FogEnd = 10000
Lighting.EnvironmentDiffuseScale = 1
Lighting.EnvironmentSpecularScale = 1

local SPAWN_POSITION = Vector3.new(0, 5, -15)

local function addLabel(model: Model, text: string)
	local primary = model.PrimaryPart
	if not primary then
		return
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameLabel"
	billboard.Adornee = primary
	billboard.Size = UDim2.fromOffset(200, 44)
	billboard.StudsOffset = Vector3.new(0, 4.5, 0)
	billboard.AlwaysOnTop = true

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 245, 230)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = billboard

	billboard.Parent = primary
end

-- Idempotent: clear any previous preview so a Rojo hot-resync doesn't stack rigs.
local existing = Workspace:FindFirstChild("VillainPreview")
if existing then
	existing:Destroy()
end

local previewFolder = Instance.new("Folder")
previewFolder.Name = "VillainPreview"
previewFolder.Parent = Workspace

local activeId = Appearances.ActiveVillainId
local entry = Appearances.Get(activeId)
if not entry then
	error(string.format("[VillainPreview] ActiveVillainId %q not in registry", activeId))
end

local model = entry.Build()
model:PivotTo(CFrame.new(SPAWN_POSITION))
addLabel(model, entry.DisplayName)
model.Parent = previewFolder

-- ===== Sway animation =====
-- Detach the hanging accessories (cords, bells, skulls + their eyes, lichen)
-- from the root weld and animate their CFrame each frame. Parts on the same
-- branch share a phase so a branch's trinkets sway as a unit.
do
	local function branchKey(name: string): string?
		return name:match("^Cord(%d+)$")
			or name:match("^Bell(%d+)$")
			or name:match("^BellLip(%d+)$")
			or name:match("^Skull(%d+)$")
			or name:match("^SkullEyeL(%d+)$")
			or name:match("^SkullEyeR(%d+)$")
			or name:match("^Lichen(%d+)_%d+$")
	end

	type Group = { parts: { BasePart }, originals: { CFrame } }
	local groups: { [string]: Group } = {}

	for _, descendant in model:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		local key = branchKey(descendant.Name)
		if not key then
			continue
		end
		for _, child in descendant:GetChildren() do
			if child:IsA("WeldConstraint") then
				child:Destroy()
			end
		end
		descendant.Anchored = true
		local group = groups[key]
		if not group then
			group = { parts = {}, originals = {} }
			groups[key] = group
		end
		table.insert(group.parts, descendant)
		table.insert(group.originals, descendant.CFrame)
	end

	local phases: { [string]: number } = {}
	for key in groups do
		-- Phase derived from the numeric branch index so neighbouring branches
		-- get visibly different offsets without needing math.random.
		phases[key] = (tonumber(key) or 0) * 0.9
	end

	RunService.Heartbeat:Connect(function()
		local t = os.clock()
		for key, group in groups do
			local phase = phases[key]
			local dx = math.sin(t * 1.1 + phase) * 0.18
			local dy = math.sin(t * 0.7 + phase * 1.3) * 0.06
			local dz = math.cos(t * 0.85 + phase) * 0.12
			local offset = Vector3.new(dx, dy, dz)
			for i, part in group.parts do
				part.CFrame = group.originals[i] + offset
			end
		end
	end)
end

-- ===== Auto-attack animation =====
-- The preview Hollow plays the full '1' attack cycle on a loop so you can
-- see what the move looks like without having to possess and trigger it
-- yourself. Uses the same pose values as the real lurch in PossessionService
-- (crouch → pounce → grab → return) so what you see here is what you get.
do
	local villainRoot = model.PrimaryPart :: BasePart?
	if not villainRoot then
		warn("[VillainPreview] Auto-attack disabled — no PrimaryPart on villain")
	else
		villainRoot.Anchored = true
		local originalRootCF = villainRoot.CFrame

		type Chain = {
			shoulder: Motor6D,
			elbow: Motor6D,
			shoulderRest: CFrame,
			elbowRest: CFrame,
			shoulderPivot: Vector3,
			elbowPivot: Vector3,
		}

		-- Mirrors startWalkAnimation's setupChain in PossessionService: drop
		-- any existing WeldConstraints, unanchor the segments so Motor6Ds
		-- can drive them, and build the shoulder/elbow pair tying root →
		-- upper → lower. The motors hold the limbs against the anchored
		-- villainRoot, so the rig stays in place when not animating.
		local function setupChain(upperName: string, lowerName: string): Chain?
			local upper = model:FindFirstChild(upperName) :: BasePart?
			local lower = model:FindFirstChild(lowerName) :: BasePart?
			if not upper or not lower then
				return nil
			end
			for _, child in upper:GetChildren() do
				if child:IsA("WeldConstraint") then
					child:Destroy()
				end
			end
			for _, child in lower:GetChildren() do
				if child:IsA("WeldConstraint") then
					child:Destroy()
				end
			end
			upper.Anchored = false
			lower.Anchored = false

			local shoulderRest = villainRoot.CFrame:ToObjectSpace(upper.CFrame)
			local shoulderMotor = Instance.new("Motor6D")
			shoulderMotor.Name = upperName .. "Motor"
			shoulderMotor.Part0 = villainRoot
			shoulderMotor.Part1 = upper
			shoulderMotor.C0 = shoulderRest
			shoulderMotor.C1 = CFrame.new()
			shoulderMotor.Parent = villainRoot

			local elbowRest = upper.CFrame:ToObjectSpace(lower.CFrame)
			local elbowMotor = Instance.new("Motor6D")
			elbowMotor.Name = lowerName .. "Motor"
			elbowMotor.Part0 = upper
			elbowMotor.Part1 = lower
			elbowMotor.C0 = elbowRest
			elbowMotor.C1 = CFrame.new()
			elbowMotor.Parent = upper

			return {
				shoulder = shoulderMotor,
				elbow = elbowMotor,
				shoulderRest = shoulderRest,
				elbowRest = elbowRest,
				shoulderPivot = shoulderRest.Position + Vector3.new(0, upper.Size.Y / 2, 0),
				elbowPivot = elbowRest.Position + Vector3.new(0, lower.Size.Y / 2, 0),
			}
		end

		local armL = setupChain("ArmL_Upper", "ArmL_Lower")
		local armR = setupChain("ArmR_Upper", "ArmR_Lower")
		local legL = setupChain("LegL_Upper", "LegL_Lower")
		local legR = setupChain("LegR_Upper", "LegR_Lower")

		if armL and armR and legL and legR then
			-- Compute target C0s for a (shoulderAngle, elbowAngle) pose.
			local function chainC0s(chain: Chain, sDeg: number, eDeg: number): (CFrame, CFrame)
				local sP = CFrame.new(chain.shoulderPivot)
				local eP = CFrame.new(chain.elbowPivot)
				return sP * CFrame.Angles(math.rad(sDeg), 0, 0) * sP:Inverse() * chain.shoulderRest,
					eP * CFrame.Angles(math.rad(eDeg), 0, 0) * eP:Inverse() * chain.elbowRest
			end

			local function tweenChain(chain: Chain, sDeg: number, eDeg: number, dur: number)
				local startS, startE = chain.shoulder.C0, chain.elbow.C0
				local endS, endE = chainC0s(chain, sDeg, eDeg)
				task.spawn(function()
					local t0 = os.clock()
					while os.clock() - t0 < dur do
						local a = math.clamp((os.clock() - t0) / dur, 0, 1)
						chain.shoulder.C0 = startS:Lerp(endS, a)
						chain.elbow.C0 = startE:Lerp(endE, a)
						task.wait()
					end
					chain.shoulder.C0 = endS
					chain.elbow.C0 = endE
				end)
			end

			-- Animate the anchored root to an absolute world CFrame. Pass
			-- `originalRootCF * offset` if you want pose-relative motion (the
			-- crouch/return), or a world-space target (the pounce/lurch).
			local function tweenRoot(targetCF: CFrame, dur: number)
				local startCF = villainRoot.CFrame
				task.spawn(function()
					local t0 = os.clock()
					while os.clock() - t0 < dur do
						local a = math.clamp((os.clock() - t0) / dur, 0, 1)
						villainRoot.CFrame = startCF:Lerp(targetCF, a)
						task.wait()
					end
					villainRoot.CFrame = targetCF
				end)
			end

			-- ===== Target detection =====
			-- Same logic as PossessionService.findGrabTarget: 12-stud range,
			-- front 150° cone, 5-stud point-blank window where the cone is
			-- ignored. Also requires a clear line-of-sight raycast — if the
			-- test wall is between the Hollow and the player, no attack.
			local armRLower = model:FindFirstChild("ArmR_Lower") :: BasePart?
			local GRAB_RANGE = 12
			local GRAB_CLOSE_RANGE = 5
			local minDot = math.cos(math.rad(150 / 2))

			local function hasLineOfSight(targetChar: Model, targetPos: Vector3): boolean
				local rayParams = RaycastParams.new()
				rayParams.FilterType = Enum.RaycastFilterType.Exclude
				rayParams.FilterDescendantsInstances = { model, targetChar }
				local origin = villainRoot.Position
				local direction = targetPos - origin
				return Workspace:Raycast(origin, direction, rayParams) == nil
			end

			local function findTarget(): Model?
				local forwardDir = villainRoot.CFrame.LookVector
				local nearest: Model?, nearestDist = nil, GRAB_RANGE
				for _, player in Players:GetPlayers() do
					local char = player.Character
					if not char then
						continue
					end
					local hum = char:FindFirstChildOfClass("Humanoid")
					local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
					if not hum or hum.Health <= 0 or not hrp then
						continue
					end
					local toTarget = hrp.Position - villainRoot.Position
					local d = toTarget.Magnitude
					if d > nearestDist then
						continue
					end
					if d > GRAB_CLOSE_RANGE and d > 0.001 then
						local dot = forwardDir:Dot(toTarget.Unit)
						if dot < minDot then
							continue
						end
					end
					if not hasLineOfSight(char, hrp.Position) then
						continue
					end
					nearest = char
					nearestDist = d
				end
				return nearest
			end

			-- ===== Grab pin =====
			-- Pin the target player's head to the Hollow's right hand with
			-- AlignPosition + AlignOrientation. PlatformStand=true silences
			-- the player's Humanoid so they can't walk out of the grip; their
			-- own client-side Motor6Ds drag the body along under the head.
			type Pin = {
				head: BasePart,
				humanoid: Humanoid?,
				handAtt: Attachment,
				headAtt: Attachment,
				alignPos: AlignPosition,
			}
			local function pinTarget(targetChar: Model): Pin?
				local head = targetChar:FindFirstChild("Head") :: BasePart?
				local humanoid = targetChar:FindFirstChildOfClass("Humanoid")
				if not head or not armRLower then
					return nil
				end
				if humanoid then
					humanoid.PlatformStand = true
				end
				local handAtt = Instance.new("Attachment")
				handAtt.Name = "PreviewGrabHand"
				handAtt.CFrame = CFrame.new(0, -armRLower.Size.Y / 2, 0)
				handAtt.Parent = armRLower
				local headAtt = Instance.new("Attachment")
				headAtt.Name = "PreviewGrabHead"
				headAtt.Parent = head
				local alignPos = Instance.new("AlignPosition")
				alignPos.Name = "PreviewGrabAlignPos"
				alignPos.Mode = Enum.PositionAlignmentMode.TwoAttachment
				alignPos.Attachment0 = headAtt
				alignPos.Attachment1 = handAtt
				alignPos.RigidityEnabled = true
				alignPos.Parent = head
				return {
					head = head,
					humanoid = humanoid,
					handAtt = handAtt,
					headAtt = headAtt,
					alignPos = alignPos,
				}
			end

			local function releasePin(pin: Pin?)
				if not pin then
					return
				end
				if pin.alignPos.Parent then
					pin.alignPos:Destroy()
				end
				if pin.handAtt.Parent then
					pin.handAtt:Destroy()
				end
				if pin.headAtt.Parent then
					pin.headAtt:Destroy()
				end
				if pin.humanoid then
					pin.humanoid.PlatformStand = false
				end
			end

			-- ===== Full attack on a target =====
			-- Crouch → pounce (lurch the root toward the player) → pin the
			-- player's head and raise the arm overhead → hold → release and
			-- snap back to spawn. Mirrors the structure of the player's '1'
			-- attack in PossessionService.
			local function performAttack(targetChar: Model)
				local targetHRP = targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not targetHRP then
					return
				end

				-- Compute pounce-end CFrame: 3 studs short of the player,
				-- facing horizontally toward them, at the Hollow's current Y.
				local horizontalDelta = Vector3.new(
					targetHRP.Position.X - villainRoot.Position.X,
					0,
					targetHRP.Position.Z - villainRoot.Position.Z
				)
				local horizontalDist = horizontalDelta.Magnitude
				if horizontalDist < 0.001 then
					return
				end
				local forwardDir = horizontalDelta / horizontalDist
				local LURCH_END_GAP = 3
				local pounceEndPos = Vector3.new(
					targetHRP.Position.X - forwardDir.X * LURCH_END_GAP,
					originalRootCF.Position.Y,
					targetHRP.Position.Z - forwardDir.Z * LURCH_END_GAP
				)
				local pounceEndCF = CFrame.lookAt(
					pounceEndPos,
					Vector3.new(targetHRP.Position.X, pounceEndPos.Y, targetHRP.Position.Z)
				)

				-- CROUCH (limbs only, body drops 1.5 in place)
				tweenChain(armL, 100, 30, 0.13)
				tweenChain(armR, 100, 30, 0.13)
				tweenChain(legL, 80, -130, 0.13)
				tweenChain(legR, 80, -130, 0.13)
				tweenRoot(originalRootCF * CFrame.new(0, -1.5, 0), 0.13)
				task.wait(0.13)

				-- POUNCE (limbs extend, body lurches to pounceEndCF + pitch/lift)
				tweenChain(armL, 85, 10, 0.27)
				tweenChain(armR, 85, 10, 0.27)
				tweenChain(legL, -40, -20, 0.27)
				tweenChain(legR, -40, -20, 0.27)
				tweenRoot(
					pounceEndCF * CFrame.new(0, 0.5, 0) * CFrame.Angles(math.rad(-15), 0, 0),
					0.27
				)
				task.wait(0.27)

				-- GRAB — pin the player, raise arm, body un-pitches at pounceEnd.
				-- Initial-connection hit: the moment of contact deals a chunk
				-- of damage (20% of MaxHealth) before the slow choke begins.
				-- That's the "tackle" beat — getting grabbed by the Hollow
				-- already hurts; the 15s drain after is the choke proper.
				local pin = pinTarget(targetChar)
				if pin and pin.humanoid then
					local INITIAL_HIT_FRACTION = 0.07
					local hum = pin.humanoid
					hum.Health = math.max(0, hum.Health - hum.MaxHealth * INITIAL_HIT_FRACTION)
				end
				tweenChain(armR, 140, 30, 0.35)
				tweenRoot(pounceEndCF, 0.35)
				task.wait(0.35)

				-- HOLD — drain the player's HP over 15 seconds. Held victims
				-- die at the end of the count if nothing releases them. Loop
				-- exits early if:
				--   • the Humanoid hits 0 (they're dead — keep holding a
				--     corpse and the auto-respawn just leaves us with a stale
				--     pin),
				--   • the pin's attachments lose their parent (character
				--     respawn destroyed the head mid-hold),
				--   • pinTarget never built a pin (no Head / arm — bail).
				--
				-- Damage rate has to account for the default Roblox health
				-- regen (1%/sec of MaxHealth) — without that compensation the
				-- regen partially cancels our drain and the player survives
				-- past 15s. Effective drain = MaxHealth/15 + 1% MaxHealth, so
				-- net (after regen) ≈ MaxHealth/15 → death at ~15s.
				local DEATH_DURATION = 15
				local PLAYER_REGEN_PER_SEC = 0.01
				local TICK = 0.1
				local heldHum = pin and pin.humanoid
				local hpPerSecond = if heldHum
					then heldHum.MaxHealth / DEATH_DURATION + heldHum.MaxHealth * PLAYER_REGEN_PER_SEC
					else 0
				local elapsed = 0
				while elapsed < DEATH_DURATION do
					if
						not pin
						or not pin.alignPos.Parent
						or not pin.head.Parent
						or not heldHum
						or heldHum.Health <= 0
					then
						break
					end
					heldHum.Health = math.max(0, heldHum.Health - hpPerSecond * TICK)
					task.wait(TICK)
					elapsed += TICK
				end

				-- RELEASE — drop the player (corpse or otherwise) and snap home
				releasePin(pin)
				tweenChain(armL, 0, 0, 0.5)
				tweenChain(armR, 0, 0, 0.5)
				tweenChain(legL, 0, 0, 0.5)
				tweenChain(legR, 0, 0, 0.5)
				tweenRoot(originalRootCF, 0.5)
				task.wait(0.5)
			end

			-- ===== Detection loop =====
			-- Scan every 0.3s; when a valid target appears, attack. Two-
			-- second cooldown after each attack so the Hollow doesn't
			-- immediately re-grab the same player they just dropped.
			task.spawn(function()
				while villainRoot.Parent do
					local target = findTarget()
					if target then
						performAttack(target)
						task.wait(2)
					else
						task.wait(0.3)
					end
				end
			end)
		else
			warn("[VillainPreview] Auto-attack disabled — limb segments not found on preview Hollow")
		end
	end
end

-- ===== Line-of-sight test wall =====
-- Solid wall halfway between spawn (~0,1,0) and the villain (~0,5,-15). Walk
-- straight at the villain (wall blocks line-of-sight → halved breathing range)
-- versus going around the side (clear LOS → full range). The Output log's
-- obstructed=true/false flag flips as you cross from one to the other.
do
	local wall = Instance.new("Part")
	wall.Name = "TestWall"
	wall.Size = Vector3.new(20, 10, 1)
	wall.Position = Vector3.new(0, 5, -8)
	wall.Color = Color3.fromRGB(170, 170, 175)
	wall.Material = Enum.Material.Concrete
	wall.Anchored = true
	wall.CanCollide = true
	wall.Parent = previewFolder

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "WallLabel"
	billboard.Adornee = wall
	billboard.Size = UDim2.fromOffset(280, 44)
	billboard.StudsOffset = Vector3.new(0, 6, 0)
	billboard.AlwaysOnTop = true
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = "Test Wall — walk around to compare"
	text.TextColor3 = Color3.fromRGB(255, 245, 230)
	text.TextStrokeTransparency = 0
	text.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.Parent = billboard
	billboard.Parent = wall
end

-- ===== Test dummies =====
-- Three simple R6-style dummies near the spawn pad. Anchored so they stay put
-- when bumped; each has a Humanoid so they show a name/health bar overhead and
-- could later be used for damage/interaction testing.
do
	local function buildDummy(name: string, position: Vector3): Model
		local skin = Color3.fromRGB(245, 205, 130)
		local shirt = Color3.fromRGB(110, 120, 170)
		local pants = Color3.fromRGB(60, 80, 120)

		local function newDummyPart(partName: string, size: Vector3, color: Color3, offset: Vector3): Part
			local p = Instance.new("Part")
			p.Name = partName
			p.Size = size
			p.Position = position + offset
			p.Color = color
			p.Material = Enum.Material.SmoothPlastic
			p.Anchored = true
			-- CanCollide = false: keeps the Hollow's collidable chassis from
			-- being pushed up when it walks into a dummy. Attacks find the
			-- dummy via FindFirstChild / GetDescendants, not via collision.
			p.CanCollide = false
			p.TopSurface = Enum.SurfaceType.Smooth
			p.BottomSurface = Enum.SurfaceType.Smooth
			return p
		end

		local model = Instance.new("Model")
		model.Name = name

		local hrp = newDummyPart("HumanoidRootPart", Vector3.new(2, 2, 1), Color3.new(), Vector3.new(0, 0, 0))
		hrp.Transparency = 1
		hrp.CanCollide = false
		hrp.Parent = model

		local torso = newDummyPart("Torso", Vector3.new(2, 2, 1), shirt, Vector3.new(0, 0, 0))
		torso.Parent = model

		local head = newDummyPart("Head", Vector3.new(2, 1, 1), skin, Vector3.new(0, 1.5, 0))
		head.Parent = model
		-- Two simple dark eye dots so each dummy reads as facing forward.
		local eyeL = newDummyPart("EyeL", Vector3.new(0.2, 0.2, 0.05), Color3.fromRGB(20, 15, 15), Vector3.new(-0.4, 1.6, -0.5))
		eyeL.Parent = model
		local eyeR = newDummyPart("EyeR", Vector3.new(0.2, 0.2, 0.05), Color3.fromRGB(20, 15, 15), Vector3.new(0.4, 1.6, -0.5))
		eyeR.Parent = model

		newDummyPart("Left Arm", Vector3.new(1, 2, 1), skin, Vector3.new(-1.5, 0, 0)).Parent = model
		newDummyPart("Right Arm", Vector3.new(1, 2, 1), skin, Vector3.new(1.5, 0, 0)).Parent = model
		newDummyPart("Left Leg", Vector3.new(1, 2, 1), pants, Vector3.new(-0.5, -2, 0)).Parent = model
		newDummyPart("Right Leg", Vector3.new(1, 2, 1), pants, Vector3.new(0.5, -2, 0)).Parent = model

		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth = 100
		humanoid.Health = 100
		humanoid.DisplayName = name
		humanoid.Parent = model

		model.PrimaryPart = hrp
		return model
	end

	local dummiesFolder = Workspace:FindFirstChild("TestDummies")
	if dummiesFolder then
		dummiesFolder:Destroy()
	end
	dummiesFolder = Instance.new("Folder")
	dummiesFolder.Name = "TestDummies"
	dummiesFolder.Parent = Workspace

	-- A small row 5 studs east of the spawn pad (which sits at 0,1,0).
	-- Y=3 puts each dummy's feet at ground level on the baseplate.
	local positions = {
		Vector3.new(5, 3, 4),
		Vector3.new(5, 3, 0),
		Vector3.new(5, 3, -4),
	}
	for i, pos in positions do
		local dummy = buildDummy("Test Dummy " .. i, pos)
		dummy.Parent = dummiesFolder
	end
	print(string.format("[VillainPreview] Spawned %d test dummies near spawn", #positions))

	-- ===== Player-fidelity dummies =====
	-- The simple dummies above are anchored, jointless, and CanCollide=false
	-- on every part — useful for isolated grab/release testing but they don't
	-- exercise the code paths that a real player's character would hit. These
	-- ones mirror Roblox's actual R6 character: unanchored parts, CanCollide
	-- on the body, and a full Motor6D skeleton (RootJoint, Neck, both
	-- Shoulders, both Hips) connecting everything. Use them to verify that
	-- the grab works on a real player's rig.
	local function buildPlayerDummy(name: string, position: Vector3): Model
		local shirt = Color3.fromRGB(180, 60, 60) -- red so they're distinguishable from the simple dummies
		local pants = Color3.fromRGB(90, 40, 40)
		local skin = Color3.fromRGB(245, 205, 130)

		local function newPart(partName: string, size: Vector3, color: Color3, offset: Vector3, canCollide: boolean): Part
			local p = Instance.new("Part")
			p.Name = partName
			p.Size = size
			p.Position = position + offset
			p.Color = color
			p.Material = Enum.Material.SmoothPlastic
			p.Anchored = false
			p.CanCollide = canCollide
			p.TopSurface = Enum.SurfaceType.Smooth
			p.BottomSurface = Enum.SurfaceType.Smooth
			return p
		end

		local model = Instance.new("Model")
		model.Name = name

		local hrp = newPart("HumanoidRootPart", Vector3.new(2, 2, 1), Color3.new(), Vector3.new(0, 0, 0), false)
		hrp.Transparency = 1
		hrp.Parent = model

		local torso = newPart("Torso", Vector3.new(2, 2, 1), shirt, Vector3.new(0, 0, 0), true)
		torso.Parent = model

		local head = newPart("Head", Vector3.new(2, 1, 1), skin, Vector3.new(0, 1.5, 0), true)
		head.Parent = model
		local eyeL = newPart(
			"EyeL", Vector3.new(0.2, 0.2, 0.05), Color3.fromRGB(20, 15, 15),
			Vector3.new(-0.4, 1.6, -0.5), false
		)
		eyeL.Parent = model
		local eyeR = newPart(
			"EyeR", Vector3.new(0.2, 0.2, 0.05), Color3.fromRGB(20, 15, 15),
			Vector3.new(0.4, 1.6, -0.5), false
		)
		eyeR.Parent = model

		local rightArm = newPart("Right Arm", Vector3.new(1, 2, 1), skin, Vector3.new(1.5, 0, 0), true)
		rightArm.Parent = model
		local leftArm = newPart("Left Arm", Vector3.new(1, 2, 1), skin, Vector3.new(-1.5, 0, 0), true)
		leftArm.Parent = model
		local rightLeg = newPart("Right Leg", Vector3.new(1, 2, 1), pants, Vector3.new(0.5, -2, 0), true)
		rightLeg.Parent = model
		local leftLeg = newPart("Left Leg", Vector3.new(1, 2, 1), pants, Vector3.new(-0.5, -2, 0), true)
		leftLeg.Parent = model

		-- Motor6D joints — this is the key difference vs the simple dummies.
		-- Standard R6 C0/C1 offsets, joint at the surface where the two parts
		-- meet.
		local function newJoint(jointName: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame)
			local j = Instance.new("Motor6D")
			j.Name = jointName
			j.Part0 = part0
			j.Part1 = part1
			j.C0 = c0
			j.C1 = c1
			j.Parent = part0
		end
		newJoint("RootJoint", hrp, torso, CFrame.new(), CFrame.new())
		newJoint("Neck", torso, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.5, 0))
		newJoint("Right Shoulder", torso, rightArm, CFrame.new(1, 0.5, 0), CFrame.new(-0.5, 0.5, 0))
		newJoint("Left Shoulder", torso, leftArm, CFrame.new(-1, 0.5, 0), CFrame.new(0.5, 0.5, 0))
		newJoint("Right Hip", torso, rightLeg, CFrame.new(0.5, -1, 0), CFrame.new(0, 1, 0))
		newJoint("Left Hip", torso, leftLeg, CFrame.new(-0.5, -1, 0), CFrame.new(0, 1, 0))

		-- Eyes ride along on the head via WeldConstraints — same pattern the
		-- grab code uses for cosmetics.
		local function weldToHead(part: BasePart)
			local w = Instance.new("WeldConstraint")
			w.Part0 = head
			w.Part1 = part
			w.Parent = part
		end
		weldToHead(eyeL)
		weldToHead(eyeR)

		-- R6 Humanoid with default settings — matches what Roblox creates
		-- for a real player joining the game.
		local humanoid = Instance.new("Humanoid")
		humanoid.RigType = Enum.HumanoidRigType.R6
		humanoid.MaxHealth = 100
		humanoid.Health = 100
		humanoid.DisplayName = name
		humanoid.WalkSpeed = 0 -- so they stay put for testing instead of wandering
		humanoid.Parent = model

		model.PrimaryPart = hrp
		return model
	end

	-- Spawn a row west of the spawn pad, mirroring the simple-dummy layout.
	local playerPositions = {
		Vector3.new(-5, 3, 4),
		Vector3.new(-5, 3, 0),
		Vector3.new(-5, 3, -4),
	}
	for i, pos in playerPositions do
		local dummy = buildPlayerDummy("Player Dummy " .. i, pos)
		dummy.Parent = dummiesFolder
	end
	print(string.format("[VillainPreview] Spawned %d player-fidelity dummies west of spawn", #playerPositions))
end

print(string.format("[VillainPreview] Spawned %s at %s", entry.DisplayName, tostring(SPAWN_POSITION)))
