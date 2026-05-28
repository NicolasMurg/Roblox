--!strict
-- PossessionService: lets an authorized player wear the active villain rig in
-- place of their normal character.
--
-- Implementation: the player's normal character keeps its Humanoid (so they
-- still control movement, jumping, collisions). The character's BaseParts and
-- Decals are made transparent, and a fresh villain Model is welded to the
-- HumanoidRootPart so it follows the player around.
--
-- Communication: a plain RemoteEvent in ReplicatedStorage.Remotes, not Knit's
-- Service:Client mechanism. Knit 1.7 was returning Promises that never settled
-- for this method — RemoteEvent is fire-and-forget and dead-simple.
--
-- Possession state survives respawn via the CharacterAdded hook.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Appearances = require(ReplicatedStorage.Shared.Modules.VillainAppearances)

local AUTHORIZED_USERNAME = "Mlg6423"
local REMOTE_NAME = "TogglePossession"
local REMOTE_NAME_GRAB = "ToggleGrab"
-- Escape minigame remotes (shared with the AI Hollow in VillainPreview).
-- EscapeMinigame: server → client, FireClient(victim, true/false) to
-- show/hide the struggle bar. EscapeEscaped: client → server, the victim
-- fires it when they clear all the markers and should be released.
local REMOTE_NAME_ESCAPE = "EscapeMinigame"
local REMOTE_NAME_ESCAPED = "EscapeEscaped"
-- Populated in KnitStart; read by startGrab/releaseGrab to drive the
-- victim's escape UI.
local escapeMinigameRemote: RemoteEvent? = nil

-- Vertical offset from the player's HumanoidRootPart to the villain rig's
-- Root. Tuned so the villain's feet land near the player's feet.
local VILLAIN_VERTICAL_OFFSET = 2

-- Grab range is derived from the arm at grab time (sum of upper + lower
-- segment lengths), so reach scales with the rig instead of being a magic
-- number divorced from the model.

-- Stash each shoulder/elbow Motor6D's rest C0 so the grab code can rotate
-- around it without losing the reference pose (the walk animation overwrites
-- motor.C0 every frame).
local motorRestC0: { [Motor6D]: CFrame } = {}

-- Per-player hold state. Empty entry = not holding; populated = currently
-- gripping a target with the right arm.
-- Captured Motor6D so we can rebuild the target's pre-grab skeleton on
-- release. Player rigs (and the player-fidelity dummies) come with these
-- joints already in place; the grab tears them out so BallSocket ragdoll
-- joints aren't fighting rigid Motor6Ds, and re-creates them on release.
type SavedMotor6D = {
	name: string,
	part0: BasePart,
	part1: BasePart,
	c0: CFrame,
	c1: CFrame,
	parent: Instance,
}

type HoldState = {
	target: Model,
	targetHRP: BasePart,
	targetHead: BasePart,
	targetHum: Humanoid?,
	ragdollJoints: { BallSocketConstraint },
	ragdollAttachments: { Attachment },
	attachments: { Attachment },
	constraints: { Instance },
	bodyParts: { BasePart },
	-- Original rigid pose captured at grab start, keyed by BasePart →
	-- CFrame offset from the dummy's HumanoidRootPart. Used on release to
	-- snap the body back to its pre-ragdoll T-pose so it doesn't freeze
	-- mid-flop.
	originalHRPToPart: { [BasePart]: CFrame },
	savedMotor6Ds: { SavedMotor6D },
}
local holdState: { [Player]: HoldState } = {}

local PossessionService = Knit.CreateService({
	Name = "PossessionService",
	_wantsPossession = {} :: { [Player]: boolean },
})

-- When the character is "hidden" we also kill its hitbox so the villain's
-- visible chassis becomes the only collider the world sees. HumanoidRootPart
-- is left intact — it's the Humanoid's movement anchor.
local function setCharacterShown(char: Model, shown: boolean)
	local transparency = if shown then 0 else 1
	for _, descendant in char:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			descendant.Transparency = transparency
			descendant.CanCollide = shown
			descendant.CanQuery = shown
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = transparency
		end
	end
end

-- Cosmetic part-name prefixes — these stay non-collidable so dangly bits don't
-- catch on geometry. Anything not matching is treated as chassis.
local COSMETIC_PREFIXES = {
	"Eye", "Tooth", "Maw", "Branch", "Twig", "Lichen",
	"Cord", "Bell", "Skull", "Wisp", "Bloom", "Ember",
	"Crack", "Suture", "Stitch", "Wound", "Thorn",
	"Bramble", "Vine", "Rib", "Strap", "HeadWrap",
	"Cheek", "Mouth", "Brow", "Tuft",
}

local function isCosmeticName(name: string): boolean
	for _, prefix in COSMETIC_PREFIXES do
		if string.sub(name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

local function attachVillainToCharacter(villain: Model, char: Model)
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local villainRoot = villain.PrimaryPart :: BasePart
	villainRoot.Anchored = false

	local weld = Instance.new("Weld")
	weld.Name = "PossessionWeld"
	weld.Part0 = hrp
	weld.Part1 = villainRoot
	weld.C0 = CFrame.new(0, VILLAIN_VERTICAL_OFFSET, 0)
	weld.C1 = CFrame.new()
	weld.Parent = villainRoot

	-- Lock HRP's pitch and roll so the R15 walk-cycle lean doesn't tilt the
	-- welded villain rig. Yaw stays free so the Humanoid can still turn the
	-- character. Removed on un-possession in _Apply.
	local oldGyro = hrp:FindFirstChild("PossessionGyro")
	if oldGyro then
		oldGyro:Destroy()
	end
	local gyro = Instance.new("BodyGyro")
	gyro.Name = "PossessionGyro"
	gyro.MaxTorque = Vector3.new(math.huge, 0, math.huge)
	gyro.CFrame = CFrame.new()
	gyro.P = 50000
	gyro.D = 1000
	gyro.Parent = hrp

	-- Disable collision on every villain part. The HumanoidRootPart is the
	-- only collider the world should ever push against. With chassis parts
	-- (especially the legs that hang below HRP) CanCollide=true, the
	-- BodyGyro's huge X/Z torque plus the secondary ground contact at the
	-- legs precessed the assembly into a slow yaw spin. CanQuery stays on
	-- so the breathing controller's raycasts still hit the villain.
	for _, descendant in villain:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= villainRoot then
			descendant.CanCollide = false
		end
	end

	-- Walk animation. Animates the Weld.C0 between HRP and villainRoot so the
	-- entire rig sways and lurches forward while moving — looks like a slow,
	-- heavy stalker. Idle plays a subtle breathing-like dip.
	local humanoid = char:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local restC0 = weld.C0
		local walkPhase = 0
		local connection
		connection = RunService.Heartbeat:Connect(function(dt)
			if not weld.Parent then
				connection:Disconnect()
				return
			end
			-- During a lurch the startGrab pounce code drives weld.C0
			-- directly (crouch ↓, then pounce-pitch). Stand aside.
			if villain:GetAttribute("InLurch") then
				return
			end
			local moving = humanoid.MoveDirection.Magnitude > 0.1
			if moving then
				-- ~0.87 Hz step cycle — paced to roughly match the default
				-- WalkSpeed so the lurch reads as cause-and-effect with the
				-- character's actual travel. Keep startWalkAnimation in sync.
				walkPhase += dt * 5.5
				-- Bob always pulls DOWN from rest (sin-1 ranges -2..0), making
				-- each step look like a heavy drop instead of a bouncy hop.
				local bobY = (math.sin(walkPhase * 2) - 1) * 0.2
				local swayX = math.sin(walkPhase) * 0.3
				local rollZ = math.sin(walkPhase) * math.rad(6)
				local pitchX = math.rad(-10) -- constant forward hunch while moving
				weld.C0 = restC0
					* CFrame.new(swayX, bobY, 0)
					* CFrame.Angles(pitchX, 0, rollZ)
			else
				-- Slow breathing dip — barely-visible idle motion so the rig
				-- never looks fully frozen.
				local idleY = (math.sin(os.clock() * 0.8) - 1) * 0.04
				weld.C0 = restC0 * CFrame.new(0, idleY, 0)
			end
		end)
	end
end

local function detachUpright(char: Model)
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local gyro = hrp:FindFirstChild("PossessionGyro")
	if gyro then
		gyro:Destroy()
	end
end

-- Floating accessories (cords, bells, skulls, eye-dots on skulls, lichen)
-- sway gently around their attached branch tips. Mirrors the preview rig's
-- animation in [[VillainPreview]] but tracks the moving villain root so the
-- effect follows the player as they walk around.
local function startAccessoryAnimation(villain: Model)
	local villainRoot = villain.PrimaryPart :: BasePart

	local function branchIndex(name: string): number?
		local match = string.match(name, "^Cord(%d+)$")
			or string.match(name, "^Bell(%d+)$")
			or string.match(name, "^BellLip(%d+)$")
			or string.match(name, "^Skull(%d+)$")
			or string.match(name, "^SkullEyeL(%d+)$")
			or string.match(name, "^SkullEyeR(%d+)$")
			or string.match(name, "^Lichen(%d+)_%d+$")
		return if match then tonumber(match) else nil
	end

	type Animated = { part: BasePart, offset: CFrame, phase: number }
	local animated: { Animated } = {}

	for _, descendant in villain:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		local idx = branchIndex(descendant.Name)
		if not idx then
			continue
		end
		-- Detach from the welded assembly so we can drive CFrame manually.
		for _, child in descendant:GetChildren() do
			if child:IsA("WeldConstraint") then
				child:Destroy()
			end
		end
		descendant.Anchored = true
		-- Capture the part's offset from root in root's local space. World
		-- position each frame will be (currentRootCFrame * offset) + sway.
		local offset = villainRoot.CFrame:ToObjectSpace(descendant.CFrame)
		table.insert(animated, {
			part = descendant,
			offset = offset,
			phase = idx * 0.9,
		})
	end

	if #animated == 0 then
		return
	end

	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not villain.Parent or not villainRoot.Parent then
			connection:Disconnect()
			return
		end
		local t = os.clock()
		local rootCF = villainRoot.CFrame
		for _, acc in animated do
			local dx = math.sin(t * 1.1 + acc.phase) * 0.18
			local dy = math.sin(t * 0.7 + acc.phase * 1.3) * 0.06
			local dz = math.cos(t * 0.85 + acc.phase) * 0.12
			acc.part.CFrame = (rootCF * acc.offset) + Vector3.new(dx, dy, dz)
		end
	end)
end

-- Per-limb walk animation with elbow/knee joints. Each limb is a chain of two
-- segments (upper + lower) connected by Motor6Ds: root → upper at the shoulder
-- or hip, and upper → lower at the elbow or knee. Both joints are animated
-- each frame so the limb articulates instead of swinging as a rigid stick.
local function startWalkAnimation(villain: Model, humanoid: Humanoid)
	local villainRoot = villain.PrimaryPart :: BasePart

	-- Diagnostic: list every body-segment-looking part in the rig so we can tell
	-- if the build is using split limbs (ArmL_Upper, etc.) or stale single ones
	-- (ArmL, ArmR, LegL, LegR — would mean VillainAppearances wasn't re-required).
	local foundParts = {}
	for _, descendant in villain:GetDescendants() do
		if descendant:IsA("BasePart") then
			local n = descendant.Name
			if n:match("^Arm") or n:match("^Leg") then
				table.insert(foundParts, n)
			end
		end
	end
	print("[Possession] Walk anim — rig limb parts found:", table.concat(foundParts, ", "))

	type Joint = {
		motor: Motor6D,
		restC0: CFrame,
		pivotLocal: Vector3,
		amplitude: number,
	}
	type Chain = {
		shoulder: Joint, -- root → upper segment
		elbow: Joint, -- upper → lower segment
		phaseOffset: number,
		elbowBaseBend: number, -- constant inward bend so the joint never locks straight
		elbowDirection: number, -- +1 for arms (forearm folds forward), -1 for legs (shin folds back)
	}
	local chains: { Chain } = {}

	local function destroyWelds(part: BasePart)
		for _, child in part:GetChildren() do
			if child:IsA("WeldConstraint") then
				child:Destroy()
			end
		end
	end

	local function setupChain(
		upperName: string,
		lowerName: string,
		phase: number,
		shoulderAmpDeg: number,
		elbowAmpDeg: number,
		elbowBaseDeg: number,
		elbowDirection: number
	)
		local upper = villain:FindFirstChild(upperName) :: BasePart?
		local lower = villain:FindFirstChild(lowerName) :: BasePart?
		if not upper or not lower then
			warn(string.format("[Possession] Chain setup FAILED for %s/%s — upper=%s lower=%s",
				upperName, lowerName, tostring(upper), tostring(lower)))
			return
		end
		print(string.format("[Possession] Chain setup OK for %s/%s", upperName, lowerName))
		destroyWelds(upper)
		destroyWelds(lower)

		-- Shoulder / hip: root → upper segment.
		local shoulderRest = villainRoot.CFrame:ToObjectSpace(upper.CFrame)
		local shoulderMotor = Instance.new("Motor6D")
		shoulderMotor.Name = upperName .. "Motor"
		shoulderMotor.Part0 = villainRoot
		shoulderMotor.Part1 = upper
		shoulderMotor.C0 = shoulderRest
		shoulderMotor.C1 = CFrame.new()
		shoulderMotor.Parent = villainRoot
		motorRestC0[shoulderMotor] = shoulderRest
		local shoulderPivot = shoulderRest.Position + Vector3.new(0, upper.Size.Y / 2, 0)

		-- Elbow / knee: upper → lower segment. C0 lives in upper's local space.
		local elbowRest = upper.CFrame:ToObjectSpace(lower.CFrame)
		local elbowMotor = Instance.new("Motor6D")
		elbowMotor.Name = lowerName .. "Motor"
		elbowMotor.Part0 = upper
		elbowMotor.Part1 = lower
		elbowMotor.C0 = elbowRest
		elbowMotor.C1 = CFrame.new()
		elbowMotor.Parent = upper
		-- Elbow pivot at the top of the lower segment in upper's local space.
		local elbowPivot = elbowRest.Position + Vector3.new(0, lower.Size.Y / 2, 0)

		table.insert(chains, {
			shoulder = {
				motor = shoulderMotor,
				restC0 = shoulderRest,
				pivotLocal = shoulderPivot,
				amplitude = math.rad(shoulderAmpDeg),
			},
			elbow = {
				motor = elbowMotor,
				restC0 = elbowRest,
				pivotLocal = elbowPivot,
				amplitude = math.rad(elbowAmpDeg),
			},
			phaseOffset = phase,
			elbowBaseBend = math.rad(elbowBaseDeg),
			elbowDirection = elbowDirection,
		})
	end

	-- Arms swing in opposite phase. Each leg counter-strides the same-side
	-- arm (left arm forward = left leg back). Arms fold forward at the elbow
	-- (+1); legs fold backward at the knee (-1) like a natural human gait.
	setupChain("ArmL_Upper", "ArmL_Lower", 0, 35, 25, 25, 1)
	setupChain("ArmR_Upper", "ArmR_Lower", math.pi, 35, 25, 25, 1)
	setupChain("LegL_Upper", "LegL_Lower", math.pi, 28, 30, 12, -1)
	setupChain("LegR_Upper", "LegR_Lower", 0, 28, 30, 12, -1)

	print(string.format("[Possession] Walk anim — %d chain(s) ready", #chains))
	if #chains == 0 then
		warn("[Possession] No limb chains set up. The rig is using stale single-piece limbs. "
			.. "Stop the play session (Shift+F5) and start it again (F5) so the server "
			.. "re-requires VillainAppearances with the split-limb build.")
		return
	end

	local walkPhase = 0
	local intensity = 0 -- smoothed 0..1 (idle..walking) so joints ease in/out
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if not villain.Parent or not villainRoot.Parent then
			connection:Disconnect()
			return
		end

		local moving = humanoid.MoveDirection.Magnitude > 0.1
		local target = if moving then 1 else 0
		intensity = intensity + (target - intensity) * (1 - math.exp(-dt * 6))

		if moving then
			walkPhase += dt * 5.5 -- match the whole-rig walk frequency (in attachVillainToCharacter)
		end

		local inHold = villain:GetAttribute("InHold") == true
		local inLurch = villain:GetAttribute("InLurch") == true
		for _, chain in chains do
			-- During a lurch the pounce code drives every limb; during a
			-- grab only the right arm is driven (overhead pose). Skip
			-- whichever joints are externally controlled this frame.
			if inLurch then
				continue
			end
			if inHold and string.sub(chain.shoulder.motor.Name, 1, 4) == "ArmR" then
				continue
			end

			local phase = walkPhase + chain.phaseOffset
			local s = math.sin(phase)

			-- Shoulder/hip: pure forward/back swing.
			local shoulderAngle = s * chain.shoulder.amplitude * intensity

			-- Elbow/knee: a base bend (so the joint never goes ramrod-straight)
			-- plus half-amplitude sine offset, multiplied by direction so legs
			-- fold backward and arms fold forward.
			local elbowAngle = (chain.elbowBaseBend + s * chain.elbow.amplitude * 0.5)
				* intensity
				* chain.elbowDirection

			-- Apply both joints. The elbow rotation is in the upper segment's
			-- local space, so it composes correctly with the shoulder rotation.
			local sPivot = CFrame.new(chain.shoulder.pivotLocal)
			chain.shoulder.motor.C0 = sPivot * CFrame.Angles(shoulderAngle, 0, 0) * sPivot:Inverse() * chain.shoulder.restC0

			local ePivot = CFrame.new(chain.elbow.pivotLocal)
			chain.elbow.motor.C0 = ePivot * CFrame.Angles(elbowAngle, 0, 0) * ePivot:Inverse() * chain.elbow.restC0
		end
	end)
end


-- ===== Grab (hold by head with right arm) =====

local function findGrabTarget(
	originPos: Vector3,
	forwardDir: Vector3,
	ownChar: Model?,
	range: number,
	minDot: number,
	closeRange: number
): Model?
	local nearest: Model?, nearestDist = nil, range
	local function consider(model: Model)
		if model == ownChar then
			return
		end
		local hum = model:FindFirstChildOfClass("Humanoid")
		local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hum or hum.Health <= 0 or not hrp then
			return
		end
		local toTarget = hrp.Position - originPos
		local d = toTarget.Magnitude
		if d > nearestDist then
			return
		end
		-- Cone gate: anything farther than closeRange must lie within the
		-- front cone (minDot = cos(halfAngle), e.g. cos(75°) for 150°).
		-- Within closeRange the Hollow grabs in any direction — point-blank
		-- snatches don't need line-of-sight.
		if d > closeRange and d > 0.001 then
			local dot = forwardDir:Dot(toTarget.Unit)
			if dot < minDot then
				return
			end
		end
		nearest = model
		nearestDist = d
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			consider(p.Character)
		end
	end
	local dummies = workspace:FindFirstChild("TestDummies")
	if dummies then
		for _, child in dummies:GetChildren() do
			if child:IsA("Model") then
				consider(child)
			end
		end
	end
	return nearest
end

-- Rotate a shoulder/elbow motor's C0 around its pivot by the given X/Z angles
-- (relative to the rest pose stored in motorRestC0).
local function rotatedC0(motor: Motor6D, xAngle: number, zAngle: number?): CFrame?
	local rest = motorRestC0[motor]
	local part = motor.Part1
	if not rest or not part then
		return nil
	end
	local pivot = CFrame.new(rest.Position + Vector3.new(0, part.Size.Y / 2, 0))
	return pivot * CFrame.Angles(xAngle, 0, zAngle or 0) * pivot:Inverse() * rest
end

local function tweenMotor(motor: Motor6D?, targetC0: CFrame?, duration: number)
	if not motor or not targetC0 then
		return
	end
	local startC0 = motor.C0
	local t0 = os.clock()
	while os.clock() - t0 < duration do
		local a = math.clamp((os.clock() - t0) / duration, 0, 1)
		motor.C0 = startC0:Lerp(targetC0, a)
		task.wait()
	end
	motor.C0 = targetC0
end

local function releaseGrab(player: Player, villain: Model?)
	local state = holdState[player]
	if not state then
		return
	end
	holdState[player] = nil

	-- Hide the victim's escape minigame, whatever ended the grab (manual
	-- release, choke death, or a successful escape). Harmless if they never
	-- had one (dummy target) or already closed it client-side on escape.
	local victimPlayer = Players:GetPlayerFromCharacter(state.target)
	if victimPlayer and escapeMinigameRemote then
		escapeMinigameRemote:FireClient(victimPlayer, false)
	end

	-- Destroy the hand/orient constraints + their attachments so the head is
	-- no longer pinned to the Hollow's hand.
	for _, c in state.constraints do
		if c.Parent then
			c:Destroy()
		end
	end
	for _, a in state.attachments do
		if a.Parent then
			a:Destroy()
		end
	end

	if state.target.Parent then
		-- Defang the Humanoid. With RequiresNeck=true (default) and no Motor6D
		-- named "Neck", the Humanoid would die the instant we unanchor the
		-- head; BreakJointsOnDeath=true would then shatter every joint on the
		-- body. Both flags must be off, and health must be full, BEFORE we
		-- start rebuilding the rig.
		--
		-- PlatformStand was set true at grab start to silence the Humanoid
		-- during the hold. For player-rig targets we need to clear it on
		-- release so the Humanoid transitions back out of Physics state and
		-- can stand up once the body lands. Simple dummies don't care
		-- either way (their bodies are rigidly welded post-release), so
		-- clearing it is safe for both.
		if state.targetHum then
			state.targetHum.BreakJointsOnDeath = false
			state.targetHum.RequiresNeck = false
			state.targetHum.Health = state.targetHum.MaxHealth
			state.targetHum.PlatformStand = false
		end

		-- ===== Step 1: FREEZE =====
		-- Anchor every BasePart. An anchored part is authoritative on the
		-- server, ignores network ownership entirely, and won't respond to
		-- any physics or constraint forces. This is the single most important
		-- step: until this completes, the player's client is still
		-- authoritatively simulating these parts as a ragdoll, and any CFrame
		-- write we make can be overwritten by replicated client positions
		-- arriving milliseconds later. Anchoring stops the bleed.
		for _, descendant in state.target:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.AssemblyLinearVelocity = Vector3.zero
				descendant.AssemblyAngularVelocity = Vector3.zero
			end
		end

		-- Now that everything's anchored, reclaim network ownership cleanly.
		-- Anchored parts auto-revert to server ownership; the explicit calls
		-- below are belt-and-suspenders for the case where the engine hasn't
		-- yet processed the anchor flag.
		if state.targetHead.Parent then
			pcall(function()
				state.targetHead:SetNetworkOwner(nil)
			end)
		end
		if state.targetHRP.Parent then
			pcall(function()
				state.targetHRP:SetNetworkOwner(nil)
			end)
		end

		-- ===== Step 2: STRIP =====
		-- Destroy every grab/ragdoll/cosmetic joint and every old rigid weld
		-- so the dummy is reduced to bare disconnected parts. We catch Weld
		-- (legacy), WeldConstraint, and BallSocketConstraint — all the joint
		-- types we've ever created on this dummy.
		local destroyedCount = 0
		for _, descendant in state.target:GetDescendants() do
			local n = descendant.Name
			local isOurJoint = n == "RagdollJoint" or n == "DummyRigidWeld" or n == "GrabBodyWeld"
			if isOurJoint
				and (descendant:IsA("Weld")
					or descendant:IsA("WeldConstraint")
					or descendant:IsA("BallSocketConstraint"))
			then
				descendant:Destroy()
				destroyedCount += 1
			elseif descendant:IsA("Attachment") and (n == "RagdollAttachA" or n == "RagdollAttachB") then
				descendant:Destroy()
			end
		end

		-- ===== Step 3: POSITION HRP =====
		-- Compute a world-aligned HRP CFrame anchored at the head's current
		-- world position. Head is the part the Hollow was actually steering,
		-- so the snap-back happens around where the hand was — body
		-- re-extends in its original pose.
		local headOffset = state.originalHRPToPart[state.targetHead]
		local newHRPCFrame: CFrame
		if headOffset then
			newHRPCFrame = CFrame.new(state.targetHead.Position - headOffset.Position)
		else
			newHRPCFrame = CFrame.new(state.targetHRP.Position)
		end
		-- Clamp HRP Y so the dummy is guaranteed to sit comfortably above the
		-- player's feet. For an R6 dummy the legs extend ~3 studs below HRP
		-- (HRP_to_leg_bottom = 1 stud HRP half-height + 2 stud leg). If we
		-- place HRP too low, the legs spawn inside the floor and the physics
		-- solver can't push the welded assembly back out — the legs end up
		-- penetrating the ground. Using the player's HRP Y + 2 as the floor
		-- keeps the legs ~ground-level when released and gives them a tiny
		-- fall distance to settle.
		local minHRPY = state.targetHRP.Position.Y -- fallback if no playerHRP
		if player.Character then
			local playerHRP = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if playerHRP then
				minHRPY = playerHRP.Position.Y + 0.5
			end
		end
		if newHRPCFrame.Position.Y < minHRPY then
			newHRPCFrame = CFrame.new(newHRPCFrame.Position.X, minHRPY, newHRPCFrame.Position.Z)
				* (newHRPCFrame - newHRPCFrame.Position)
		end
		state.targetHRP.CFrame = newHRPCFrame
		state.targetHRP.Massless = false

		-- ===== Step 4: POSITION → UNANCHOR → RECONNECT (per part) =====
		-- For each non-HRP part: snap its CFrame to the captured T-pose,
		-- unanchor it (HRP stays anchored — it's the rock the joints tie
		-- everything to), then connect it back to HRP.
		--
		-- Two paths depending on whether the rig originally had Motor6Ds:
		--   • Player-fidelity rig (Motor6Ds were saved on grab): restore
		--     those Motor6Ds verbatim. They reconnect the whole skeleton at
		--     once (RootJoint, Neck, Shoulders, Hips → all body parts),
		--     leaving the Humanoid able to drive the character again.
		--   • Simple dummy (no Motor6Ds saved): build a fan of legacy Welds
		--     from HRP to every other part using the captured C0 offset.
		--     Welds are rigid and trivial — the dummy just falls as a single
		--     T-pose block.
		--
		-- Mixing the two would over-constrain the assembly. Pick one.
		local hasMotors = #state.savedMotor6Ds > 0
		local createdCount = 0

		-- First pass: snap CFrames and unanchor every non-HRP part. With
		-- HRP still anchored at newHRPCFrame and parts now sitting at the
		-- T-pose positions, the joints we add next have a consistent state
		-- to lock onto.
		for _, descendant in state.target:GetDescendants() do
			if descendant:IsA("BasePart") and descendant ~= state.targetHRP then
				local offset = state.originalHRPToPart[descendant]
				if offset then
					descendant.Massless = false
					descendant.CanCollide = true
					descendant.CFrame = newHRPCFrame * offset
					descendant.Anchored = false
				end
			end
		end

		if hasMotors then
			-- Restore the saved Motor6D skeleton. Each motor was created
			-- with specific Part0/Part1/C0/C1 — recreating them with the
			-- same values rebuilds the exact rig the player joined the
			-- game with, so the Humanoid can stand the body back up after
			-- the fall.
			for _, saved in state.savedMotor6Ds do
				if saved.part0.Parent and saved.part1.Parent and saved.parent.Parent then
					local m = Instance.new("Motor6D")
					m.Name = saved.name
					m.Part0 = saved.part0
					m.Part1 = saved.part1
					m.C0 = saved.c0
					m.C1 = saved.c1
					m.Parent = saved.parent
					createdCount += 1
				end
			end
		else
			-- Legacy-Weld fan-out for simple dummies. Why legacy Weld (not
			-- WeldConstraint): WeldConstraint captures the relative offset
			-- IMPLICITLY at activation. When that activation replicates to
			-- the player's client (who was authoritatively simulating the
			-- ragdoll), the client's parts may not have received the CFrame
			-- snap yet, so the client locks in RAGDOLL offsets instead of
			-- T-pose offsets — body looks shattered. Legacy Weld's C0/C1
			-- replicate as data; the client uses the exact offsets we
			-- specify regardless of live positions.
			for _, descendant in state.target:GetDescendants() do
				if descendant:IsA("BasePart") and descendant ~= state.targetHRP then
					local offset = state.originalHRPToPart[descendant]
					if offset then
						local weld = Instance.new("Weld")
						weld.Name = "DummyRigidWeld"
						weld.Part0 = state.targetHRP
						weld.Part1 = descendant
						weld.C0 = offset
						weld.C1 = CFrame.new()
						weld.Parent = state.targetHRP
						createdCount += 1
					end
				end
			end
		end

		-- ===== Step 5: RELEASE HRP =====
		-- All non-HRP parts are already unanchored but held in place by their
		-- welds to the still-anchored HRP. Unanchoring HRP now releases the
		-- entire welded assembly to fall under gravity as one rigid body.
		state.targetHRP.Anchored = false
		state.targetHRP.CanCollide = true -- so HRP itself can also catch the floor

		-- Defensive final pass: any part that wasn't iterated in Step 4 (e.g.
		-- a cosmetic missing from the snapshot) gets force-unanchored and
		-- force-collidable here. Without this, a leftover anchored part can
		-- freeze the whole welded assembly mid-air.
		for _, descendant in state.target:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = false
				descendant.CanCollide = true
				descendant.Massless = false
			end
		end

		-- Kickstart gravity. A small downward velocity guarantees the
		-- assembly registers as "moving" with the physics solver immediately
		-- rather than waiting on its first idle frame, which is when the
		-- "frozen in the air" case tends to happen.
		state.targetHRP.AssemblyLinearVelocity = Vector3.new(0, -5, 0)
		state.targetHRP.AssemblyAngularVelocity = Vector3.zero

		print(string.format(
			"[Release] %s — destroyed %d joints, created %d Welds, %d parts",
			state.target.Name,
			destroyedCount,
			createdCount,
			(function()
				local c = 0
				for _, d in state.target:GetDescendants() do
					if d:IsA("BasePart") then c += 1 end
				end
				return c
			end)()
		))
	end

	-- Leave PlatformStand = true so the Humanoid stays quiet — the dummy
	-- ragdolls on the floor instead of trying to stand back up.

	-- Drop the Hollow's right arm back to its rest pose. We tween the
	-- shoulder + elbow back to motorRestC0 and only flip InHold=false after
	-- the tween finishes — that way the walk animation (which skips ArmR
	-- while InHold=true) doesn't immediately overwrite our tween partway
	-- through with a swung pose.
	if villain then
		local villainRoot = villain.PrimaryPart
		local armRShoulder = villainRoot and (villainRoot:FindFirstChild("ArmR_UpperMotor") :: Motor6D?)
		local armRUpper = villain:FindFirstChild("ArmR_Upper")
		local armRElbow = armRUpper and (armRUpper:FindFirstChild("ArmR_LowerMotor") :: Motor6D?)
		local shoulderRest = armRShoulder and motorRestC0[armRShoulder]
		local elbowRest = armRElbow and motorRestC0[armRElbow]
		print(string.format(
			"[Release] arm tween — shoulder=%s rest=%s | elbow=%s rest=%s",
			tostring(armRShoulder ~= nil),
			tostring(shoulderRest ~= nil),
			tostring(armRElbow ~= nil),
			tostring(elbowRest ~= nil)
		))
		task.spawn(function()
			-- Run shoulder + elbow tweens in parallel. If either motor or its
			-- rest pose is missing we still need to clear InHold so the walk
			-- animation can take ArmR back over — otherwise the arm is stuck
			-- at whatever pose it was last at (typically the grab-overhead).
			if armRShoulder and shoulderRest then
				task.spawn(tweenMotor, armRShoulder, shoulderRest, 0.35)
			end
			if armRElbow and elbowRest then
				tweenMotor(armRElbow, elbowRest, 0.35)
			else
				task.wait(0.35)
			end
			-- Defensive: even if the tweens couldn't run, hard-snap to rest
			-- so the arm doesn't permanently hang overhead.
			if armRShoulder and shoulderRest then
				armRShoulder.C0 = shoulderRest
			end
			if armRElbow and elbowRest then
				armRElbow.C0 = elbowRest
			end
			villain:SetAttribute("InHold", false)
		end)
	else
		print("[Release] arm tween skipped — no villain passed")
	end
	print("[Grab] released — dummy dropped")
end

local function startGrab(player: Player, char: Model, villain: Model)
	local villainRoot = villain.PrimaryPart :: BasePart?
	if not villainRoot then
		return
	end
	local armRShoulder = villainRoot:FindFirstChild("ArmR_UpperMotor") :: Motor6D?
	local armRUpper = villain:FindFirstChild("ArmR_Upper") :: BasePart?
	local armRElbow = armRUpper and (armRUpper:FindFirstChild("ArmR_LowerMotor") :: Motor6D?)
	local armRLower = villain:FindFirstChild("ArmR_Lower") :: BasePart?
	if not (armRShoulder and armRElbow and armRLower) then
		warn("[Grab] right arm motors missing")
		return
	end

	-- Grab reach: 12 studs in the front 150° cone, or 5 studs in any
	-- direction (point-blank snatches don't need to be facing the target).
	local GRAB_RANGE = 12
	local GRAB_CLOSE_RANGE = 5
	local GRAB_CONE_DEG = 150
	local minDot = math.cos(math.rad(GRAB_CONE_DEG / 2))
	local forwardDir = villainRoot.CFrame.LookVector
	local target = findGrabTarget(villainRoot.Position, forwardDir, char, GRAB_RANGE, minDot, GRAB_CLOSE_RANGE)
	if not target then
		print(string.format(
			"[Grab] no target within %.1f studs (or %.1f / %d° cone)",
			GRAB_CLOSE_RANGE,
			GRAB_RANGE,
			GRAB_CONE_DEG
		))
		return
	end
	local targetHRP = target:FindFirstChild("HumanoidRootPart") :: BasePart?
	local targetHum = target:FindFirstChildOfClass("Humanoid")
	if not targetHRP then
		return
	end
	local playerHRP = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not playerHRP then
		return
	end
	local targetHead = target:FindFirstChild("Head") :: BasePart?
	if not targetHead then
		print("[Grab] target has no Head part")
		return
	end
	print("[Grab] grabbed", target.Name)

	-- Defang the target's Humanoid IMMEDIATELY, before we touch a single
	-- Motor6D. Defaults are RequiresNeck=true + BreakJointsOnDeath=true —
	-- the instant we destroy the Neck Motor6D below, the Humanoid notices
	-- the missing neck, declares the character dead, and BreakJointsOnDeath
	-- shatters every joint we're trying to manage. Switching these off here
	-- lets us tear out and rebuild the skeleton freely.
	if targetHum then
		targetHum.BreakJointsOnDeath = false
		targetHum.RequiresNeck = false
	end

	-- Snapshot the dummy's rigid pose BEFORE we move it. Offsets are in
	-- HRP-local space so they survive the upcoming PivotTo + ragdoll churn —
	-- on release we use these to reconstruct world positions for each part
	-- and bake them into legacy Welds as explicit C0 values.
	local originalHRPToPart: { [BasePart]: CFrame } = {}
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("BasePart") then
			originalHRPToPart[descendant] = targetHRP.CFrame:ToObjectSpace(descendant.CFrame)
		end
	end

	-- ===== Lurch (cat-pounce long-reach grab) =====
	-- If the target is >7 studs away (and inside the front cone), the Hollow
	-- coils into a kneeling crouch with both hands on the ground, then
	-- pounces forward — body pitched, all four limbs reaching/extending.
	-- The pounce ends 3 studs in front of the dummy; the existing grab tween
	-- below then raises the right arm overhead, which (via the AlignPosition
	-- tying the dummy's head to the hand) lifts the dummy off the ground.
	local LURCH_THRESHOLD = 7
	local LURCH_CROUCH_DUR = 0.13
	local LURCH_POUNCE_DUR = 0.27
	local LURCH_END_GAP = 3
	local distanceToTarget = (targetHRP.Position - villainRoot.Position).Magnitude
	if distanceToTarget > LURCH_THRESHOLD then
		local horizontalDelta = Vector3.new(
			targetHRP.Position.X - playerHRP.Position.X,
			0,
			targetHRP.Position.Z - playerHRP.Position.Z
		)
		local horizontalDist = horizontalDelta.Magnitude
		if horizontalDist > 0.001 then
			local forwardDir = horizontalDelta / horizontalDist
			local endPos = Vector3.new(
				targetHRP.Position.X - forwardDir.X * LURCH_END_GAP,
				playerHRP.Position.Y,
				targetHRP.Position.Z - forwardDir.Z * LURCH_END_GAP
			)
			local endCFrame = CFrame.lookAt(
				endPos,
				Vector3.new(targetHRP.Position.X, endPos.Y, targetHRP.Position.Z)
			)

			-- Look up every limb motor on the Hollow rig for the pose work.
			local armLUpper = villain:FindFirstChild("ArmL_Upper") :: BasePart?
			local armLShoulder = villainRoot:FindFirstChild("ArmL_UpperMotor") :: Motor6D?
			local armLElbow = armLUpper and (armLUpper:FindFirstChild("ArmL_LowerMotor") :: Motor6D?)
			local legLUpper = villain:FindFirstChild("LegL_Upper") :: BasePart?
			local legLHip = villainRoot:FindFirstChild("LegL_UpperMotor") :: Motor6D?
			local legLKnee = legLUpper and (legLUpper:FindFirstChild("LegL_LowerMotor") :: Motor6D?)
			local legRUpper = villain:FindFirstChild("LegR_Upper") :: BasePart?
			local legRHip = villainRoot:FindFirstChild("LegR_UpperMotor") :: Motor6D?
			local legRKnee = legRUpper and (legRUpper:FindFirstChild("LegR_LowerMotor") :: Motor6D?)
			local possessionWeld = villainRoot:FindFirstChild("PossessionWeld") :: Weld?
			local weldRestC0 = CFrame.new(0, VILLAIN_VERTICAL_OFFSET, 0)

			-- Stop player input and freeze the per-frame walk/idle animations
			-- by setting InLurch — both attachVillainToCharacter's weld anim
			-- and startWalkAnimation's limb anim back off when this is set,
			-- so our tweens have exclusive control.
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			local prevWalkSpeed = humanoid and humanoid.WalkSpeed or 16
			if humanoid then
				humanoid.WalkSpeed = 0
			end
			villain:SetAttribute("InLurch", true)

			local function poseMotors(specs, duration)
				for _, spec in specs do
					local motor, xDeg, zDeg = spec[1], spec[2], spec[3]
					local target = motor and rotatedC0(motor, math.rad(xDeg), math.rad(zDeg or 0))
					if motor and target then
						task.spawn(tweenMotor, motor, target, duration)
					end
				end
			end

			local function tweenWeldC0(weld, startC0, endC0, duration)
				task.spawn(function()
					local t0 = os.clock()
					while os.clock() - t0 < duration do
						if not weld.Parent then
							return
						end
						local a = math.clamp((os.clock() - t0) / duration, 0, 1)
						weld.C0 = startC0:Lerp(endC0, a)
						task.wait()
					end
					if weld.Parent then
						weld.C0 = endC0
					end
				end)
			end

			-- Phase 1 — CROUCH (kneeling tripod).
			-- Body pitches forward 55°, so the torso's long axis sits 35°
			-- above the floor (the angle the user specified). Hips +55° and
			-- shoulders +55° compensate for that body tilt — they pre-rotate
			-- the limbs by exactly the opposite of the body's pitch, so the
			-- thighs and arms come out VERTICAL in world space rather than
			-- following the tilted body. Knees +90° then fold the shins out
			-- perpendicular to the thighs, planting them flat on the floor.
			-- Elbows stay at 0° so the arms hang straight down to the ground
			-- and the hands prop the body up.
			poseMotors({
				{ armLShoulder, 55, 0 },
				{ armLElbow, 0 },
				{ armRShoulder, 55, 0 },
				{ armRElbow, 0 },
				{ legLHip, 55, 0 },
				{ legLKnee, 90 },
				{ legRHip, 55, 0 },
				{ legRKnee, 90 },
			}, LURCH_CROUCH_DUR)
			if possessionWeld then
				tweenWeldC0(
					possessionWeld,
					possessionWeld.C0,
					weldRestC0 * CFrame.new(0, -1, 0) * CFrame.Angles(math.rad(-55), 0, 0),
					LURCH_CROUCH_DUR
				)
			end
			task.wait(LURCH_CROUCH_DUR)

			-- Phase 2 — POUNCE (knees straighten and push the body forward).
			-- Body un-pitches to a shallow -15° forward lean for momentum.
			-- Knees drive to 0° (fully extended — the "push") and hips swing
			-- back to -30° so the legs trail behind. Arms reach forward at
			-- 85° / 10° to make first contact with the dummy. The player HRP
			-- dashes to endCFrame in parallel below.
			poseMotors({
				{ armLShoulder, 85, 0 },
				{ armLElbow, 10 },
				{ armRShoulder, 85, 0 },
				{ armRElbow, 10 },
				{ legLHip, -30, 0 },
				{ legLKnee, 0 },
				{ legRHip, -30, 0 },
				{ legRKnee, 0 },
			}, LURCH_POUNCE_DUR)
			if possessionWeld then
				tweenWeldC0(
					possessionWeld,
					possessionWeld.C0,
					weldRestC0 * CFrame.new(0, 0.3, 0) * CFrame.Angles(math.rad(-15), 0, 0),
					LURCH_POUNCE_DUR
				)
			end

			local startCFrame = playerHRP.CFrame
			local t0 = os.clock()
			while os.clock() - t0 < LURCH_POUNCE_DUR do
				if not playerHRP.Parent or not targetHRP.Parent then
					break
				end
				local a = math.clamp((os.clock() - t0) / LURCH_POUNCE_DUR, 0, 1)
				playerHRP.CFrame = startCFrame:Lerp(endCFrame, a)
				task.wait()
			end
			if playerHRP.Parent then
				playerHRP.CFrame = endCFrame
				playerHRP.AssemblyLinearVelocity = Vector3.zero
			end

			-- Land: body returns to neutral, attribute clears so walk anim
			-- resumes. The existing grab tween (below) immediately raises
			-- the right arm overhead — that's the "lift forward" beat.
			if possessionWeld then
				possessionWeld.C0 = weldRestC0
			end
			villain:SetAttribute("InLurch", false)
			if humanoid then
				humanoid.WalkSpeed = prevWalkSpeed
			end
		end
	end

	-- Position AND orient the dummy at the hand BEFORE we unanchor or attach
	-- constraints. Matching the player's yaw here means the AlignOrientation
	-- has no rotation to correct when it activates — no snap torque, no
	-- reaction force back into the player.
	local rHandWorld = armRLower.CFrame * CFrame.new(0, -armRLower.Size.Y / 2, 0)
	local playerRotation = playerHRP.CFrame - playerHRP.CFrame.Position
	-- Center the dummy at the hand (head sits at the hand point; body hangs below).
	target:PivotTo(CFrame.new(rHandWorld.Position - Vector3.new(0, 0.5, 0)) * playerRotation)

	-- Wipe any leftover grab joints/welds from a prior grab on this dummy.
	-- This includes the rigid welds the release step added to lock the dummy
	-- back together — without removing them, the new ragdoll joints would
	-- fight against rigid welds and the body would refuse to ragdoll.
	for _, descendant in target:GetDescendants() do
		if descendant.Name == "GrabBodyWeld"
			or descendant.Name == "RagdollJoint"
			or descendant.Name == "RagdollAttachA"
			or descendant.Name == "RagdollAttachB"
			or descendant.Name == "DummyRigidWeld"
		then
			descendant:Destroy()
		end
	end

	-- Look up R6 body parts. Anything missing is fine — we just skip that joint.
	local function findPart(name: string): BasePart?
		return target:FindFirstChild(name) :: BasePart?
	end
	local torso = findPart("Torso")
	local leftArm = findPart("Left Arm")
	local rightArm = findPart("Right Arm")
	local leftLeg = findPart("Left Leg")
	local rightLeg = findPart("Right Leg")

	local bodyParts: { BasePart } = {}
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(bodyParts, descendant)
			descendant.CanCollide = false
			-- Massless during the 200ms grab window so the limp body's weight
			-- can't kick a reaction force into the player's arm. We restore
			-- mass on every part except the head once that window closes.
			descendant.Massless = true
			descendant.Anchored = false
		end
	end

	-- Save and tear out the target's existing Motor6D skeleton (RootJoint,
	-- Neck, Shoulders, Hips, etc.). Player-fidelity dummies and real player
	-- characters come with these — they hold the body rigid and would
	-- override the BallSocket ragdoll joints below if left in place. Simple
	-- dummies have no Motor6Ds so this list ends up empty for them. Both
	-- shapes get restored verbatim on release.
	local savedMotor6Ds: { SavedMotor6D } = {}
	for _, descendant in target:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Part0 and descendant.Part1 and descendant.Parent then
			table.insert(savedMotor6Ds, {
				name = descendant.Name,
				part0 = descendant.Part0,
				part1 = descendant.Part1,
				c0 = descendant.C0,
				c1 = descendant.C1,
				parent = descendant.Parent,
			})
			descendant:Destroy()
		end
	end
	if #savedMotor6Ds > 0 then
		print(string.format("[Grab] stashed %d Motor6Ds from %s", #savedMotor6Ds, target.Name))
	end

	-- Build the ragdoll joints — neck + shoulders + hips — as BallSocket
	-- constraints with tight swing/twist limits. Tight limits keep the dummy
	-- legibly humanoid: limbs swing under gravity but can't fold past
	-- anatomical extremes, so it droops rather than melting into a rope.
	local ragdollJoints: { BallSocketConstraint } = {}
	local ragdollAttachments: { Attachment } = {}
	local function joint(
		part0: BasePart?,
		part1: BasePart?,
		p0Pos: Vector3,
		p1Pos: Vector3,
		upperAngleDeg: number
	)
		if not part0 or not part1 then
			return
		end
		local a0 = Instance.new("Attachment")
		a0.Name = "RagdollAttachA"
		a0.CFrame = CFrame.new(p0Pos)
		a0.Parent = part0
		local a1 = Instance.new("Attachment")
		a1.Name = "RagdollAttachB"
		a1.CFrame = CFrame.new(p1Pos)
		a1.Parent = part1
		local bs = Instance.new("BallSocketConstraint")
		bs.Name = "RagdollJoint"
		bs.Attachment0 = a0
		bs.Attachment1 = a1
		bs.LimitsEnabled = true
		bs.UpperAngle = upperAngleDeg
		bs.TwistLimitsEnabled = true
		bs.TwistLowerAngle = -upperAngleDeg * 0.5
		bs.TwistUpperAngle = upperAngleDeg * 0.5
		bs.Restitution = 0
		bs.Parent = part0
		table.insert(ragdollJoints, bs)
		table.insert(ragdollAttachments, a0)
		table.insert(ragdollAttachments, a1)
	end

	-- R6 anatomy: Torso 2x2x1, Head 2x1x1 (top of torso), Arms 1x2x1 (sides),
	-- Legs 1x2x1 (below torso). Upper-angle cones tuned per joint — smaller
	-- cone = stiffer dangle.
	joint(torso, targetHead, Vector3.new(0, 1, 0), Vector3.new(0, -0.5, 0), 15)
	joint(torso, leftArm, Vector3.new(-1, 1, 0), Vector3.new(0.5, 1, 0), 25)
	joint(torso, rightArm, Vector3.new(1, 1, 0), Vector3.new(-0.5, 1, 0), 25)
	joint(torso, leftLeg, Vector3.new(-0.5, -1, 0), Vector3.new(0, 1, 0), 20)
	joint(torso, rightLeg, Vector3.new(0.5, -1, 0), Vector3.new(0, 1, 0), 20)
	-- HRP sits inside the torso — weld them so the assembly has one root and
	-- the Humanoid stays attached to the body it thinks it owns.
	if torso then
		local hrpWeld = Instance.new("WeldConstraint")
		hrpWeld.Name = "RagdollJoint"
		hrpWeld.Part0 = targetHRP
		hrpWeld.Part1 = torso
		hrpWeld.Parent = targetHRP
	end

	-- Eyes (and any other cosmetic part outside the R6 skeleton) aren't joined
	-- to anything by Motor6D in the test dummies — unanchoring them above
	-- dropped them on the floor. Weld each one to its nearest skeleton bone so
	-- it rides along: EyeL/EyeR end up welded to the Head.
	local skeleton: { BasePart } = {}
	for _, candidate in { targetHead, torso, leftArm, rightArm, leftLeg, rightLeg } do
		if candidate then
			table.insert(skeleton, candidate)
		end
	end
	local SKELETON_NAMES: { [string]: boolean } = {
		HumanoidRootPart = true, Torso = true, Head = true,
		["Left Arm"] = true, ["Right Arm"] = true,
		["Left Leg"] = true, ["Right Leg"] = true,
	}
	for _, part in bodyParts do
		if SKELETON_NAMES[part.Name] then
			continue
		end
		local nearest, nearestDist = nil :: BasePart?, math.huge
		for _, sk in skeleton do
			local d = (sk.Position - part.Position).Magnitude
			if d < nearestDist then
				nearest, nearestDist = sk, d
			end
		end
		if nearest then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "RagdollJoint"
			weld.Part0 = nearest
			weld.Part1 = part
			weld.Parent = part
		end
	end

	-- Kill any residual velocity from a previous release.
	targetHRP.AssemblyLinearVelocity = Vector3.zero
	targetHRP.AssemblyAngularVelocity = Vector3.zero
	targetHead.AssemblyLinearVelocity = Vector3.zero
	targetHead.AssemblyAngularVelocity = Vector3.zero

	-- Silence the dummy's Humanoid so its own walking/standing torques don't
	-- compete with our constraints.
	if targetHum then
		targetHum.PlatformStand = true
		targetHum:ChangeState(Enum.HumanoidStateType.Physics)
	end

	-- Hand network ownership of the head (which becomes the dummy's root once
	-- it's the only thing constrained to the player) to the player's client.
	pcall(function()
		targetHead:SetNetworkOwner(player)
	end)

	-- Attachments for the hand/orient constraints — these pin the HEAD only.
	local handAttachment = Instance.new("Attachment")
	handAttachment.Name = "GrabHandPoint"
	handAttachment.CFrame = CFrame.new(0, -armRLower.Size.Y / 2, 0)
	handAttachment.Parent = armRLower

	local dummyHeadAttachment = Instance.new("Attachment")
	dummyHeadAttachment.Name = "GrabHeadPoint"
	dummyHeadAttachment.CFrame = CFrame.new()
	dummyHeadAttachment.Parent = targetHead

	local playerOrientAttachment = playerHRP:FindFirstChild("GrabOrientRef") :: Attachment?
	if not playerOrientAttachment then
		local a = Instance.new("Attachment")
		a.Name = "GrabOrientRef"
		a.Parent = playerHRP
		playerOrientAttachment = a
	end
	local dummyOrientAttachment = Instance.new("Attachment")
	dummyOrientAttachment.Name = "GrabOrientRef"
	dummyOrientAttachment.Parent = targetHead

	-- AlignPosition: dummy's head is pulled to the Hollow's hand.
	local alignPos = Instance.new("AlignPosition")
	alignPos.Name = "GrabAlignPos"
	alignPos.Mode = Enum.PositionAlignmentMode.TwoAttachment
	alignPos.Attachment0 = dummyHeadAttachment
	alignPos.Attachment1 = handAttachment
	alignPos.RigidityEnabled = true
	alignPos.Parent = targetHead

	-- AlignOrientation: only the head matches the player's facing. The rest
	-- of the body hangs from the neck ball-socket and ragdolls freely.
	local alignOrient = Instance.new("AlignOrientation")
	alignOrient.Name = "GrabAlignOrient"
	alignOrient.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	alignOrient.Attachment0 = dummyOrientAttachment
	alignOrient.Attachment1 = playerOrientAttachment
	alignOrient.RigidityEnabled = true
	alignOrient.Parent = targetHead

	-- Pose the right arm overhead (shoulder ~140° up-and-forward, elbow bend).
	task.spawn(tweenMotor, armRShoulder, rotatedC0(armRShoulder, math.rad(140), math.rad(0)), 0.35)
	task.spawn(tweenMotor, armRElbow, rotatedC0(armRElbow, math.rad(30)), 0.35)

	villain:SetAttribute("InHold", true)

	-- If the grabbed target is a real player, show their escape minigame.
	-- Dummies have no client, so GetPlayerFromCharacter returns nil and we
	-- skip it for them.
	local victimPlayer = Players:GetPlayerFromCharacter(target)
	if victimPlayer and escapeMinigameRemote then
		escapeMinigameRemote:FireClient(victimPlayer, true)
	end

	-- ===== Damage: initial hit + 15s choke drain =====
	-- Mirrors the AI-Hollow attack in VillainPreview so the player-controlled
	-- grab is just as lethal:
	--   • Initial-connection hit: 7% MaxHealth the moment the pin lands —
	--     the "tackle" beat before the choke.
	--   • Choke drain: target's HP ticks down at MaxHealth/15 + MaxHealth*0.01
	--     per second, so even with Roblox's 1%/sec health regen running the
	--     target hits 0 by 15s.
	-- Loop exits early on manual release (holdState cleared), target
	-- respawn (Humanoid Parent gone), or target death. Auto-releases the
	-- grab on death so the Hollow doesn't keep choking a corpse.
	if targetHum then
		local INITIAL_HIT_FRACTION = 0.07
		targetHum.Health = math.max(0, targetHum.Health - targetHum.MaxHealth * INITIAL_HIT_FRACTION)

		local DEATH_DURATION = 15
		local PLAYER_REGEN_PER_SEC = 0.01
		local TICK = 0.1
		local hpPerSecond = targetHum.MaxHealth / DEATH_DURATION
			+ targetHum.MaxHealth * PLAYER_REGEN_PER_SEC
		-- task.defer (not task.spawn): task.spawn runs the function
		-- synchronously up to its first yield, and the very first thing this
		-- function does is read holdState[player] — which doesn't get
		-- assigned until the bottom of startGrab. With spawn, the function
		-- sees a nil entry on iteration 1 and returns immediately, so the
		-- 7% initial hit lands but the drain never ticks. defer schedules
		-- the function for the NEXT resumption cycle, after startGrab has
		-- finished and holdState is populated.
		task.defer(function()
			local elapsed = 0
			while elapsed < DEATH_DURATION do
				local state = holdState[player]
				-- Bail if the grab ended or the target's Humanoid is gone.
				-- Also re-check it's still the SAME target — releaseGrab
				-- clears the entry and a new grab could pick up a different
				-- victim before this task ticks again.
				if not state or state.targetHum ~= targetHum or not targetHum.Parent then
					return
				end
				if targetHum.Health <= 0 then
					break
				end
				targetHum.Health = math.max(0, targetHum.Health - hpPerSecond * TICK)
				task.wait(TICK)
				elapsed += TICK
			end
			-- Auto-release: target either died or aged out of the 15s timer
			-- without dying (regen quirk). Either way, drop the body.
			if holdState[player] then
				local currentVillain = player.Character
					and (player.Character:FindFirstChild("TheHollowFinal") :: Model?)
					or nil
				releaseGrab(player, currentVillain)
			end
		end)
	end

	-- 200ms collision-free window: after the grace period, body parts (not the
	-- head, which is the held anchor) get their mass back so they dangle and
	-- swing under gravity, and re-enable collision so they don't clip through
	-- the floor/scenery. The head stays Massless so AlignPosition has nothing
	-- to push back through the player's arm.
	task.delay(0.2, function()
		if holdState[player] == nil then
			return
		end
		for _, part in bodyParts do
			if part.Parent and part ~= targetHead then
				part.Massless = false
				if part ~= targetHRP then
					part.CanCollide = true
				end
			end
		end
	end)

	holdState[player] = {
		target = target,
		targetHRP = targetHRP,
		targetHead = targetHead,
		targetHum = targetHum,
		ragdollJoints = ragdollJoints,
		ragdollAttachments = ragdollAttachments,
		attachments = { handAttachment, dummyHeadAttachment, dummyOrientAttachment, playerOrientAttachment },
		constraints = { alignPos, alignOrient },
		bodyParts = bodyParts,
		originalHRPToPart = originalHRPToPart,
		savedMotor6Ds = savedMotor6Ds,
	}
end

function PossessionService:_Apply(player: Player)
	local char = player.Character
	if not char then
		warn("[Possession] _Apply: no character for", player.Name)
		return
	end

	local existing = char:FindFirstChild("TheHollowFinal")
	-- Always release any active grab BEFORE the villain is torn down — this
	-- destroys the AlignOrientation that was pinning the dummy to the player's
	-- HRP, so an un-possessed (or rebuilt) Hollow stops dragging its prey
	-- around. Safe to call even if no grab is active.
	releaseGrab(player, existing :: Model?)
	if existing then
		existing:Destroy()
	end

	local wants = self._wantsPossession[player]
	print(string.format("[Possession] _Apply for %s — wantsPossession=%s", player.Name, tostring(wants)))

	if wants then
		setCharacterShown(char, false)
		local villain = Appearances.Build(Appearances.ActiveVillainId)
		if not villain then
			warn("[Possession] Build returned nil for", Appearances.ActiveVillainId)
			return
		end
		villain.Parent = char
		-- Capture accessory + limb offsets BEFORE welding to the player. At
		-- this point the rig is still at world origin, so ToObjectSpace
		-- returns the true local offsets. After welding, the root jumps but
		-- the WeldConstrained body parts haven't physically updated yet, which
		-- would give wrong offsets.
		startAccessoryAnimation(villain)
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if humanoid then
			startWalkAnimation(villain, humanoid)
		end
		attachVillainToCharacter(villain, char)
		local root = villain.PrimaryPart
		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		print(string.format(
			"[Possession] villain parented; descendants=%d, root pos=%s, hrp pos=%s",
			#villain:GetDescendants(),
			root and tostring(root.Position) or "nil",
			hrp and tostring(hrp.Position) or "nil"
		))
	else
		setCharacterShown(char, true)
		detachUpright(char)
	end
end

function PossessionService:KnitStart()
	-- Create / find the toggle RemoteEvent under ReplicatedStorage.Remotes.
	local remotes = ReplicatedStorage:FindFirstChild("Remotes") :: Folder?
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	assert(remotes)

	local toggleEvent = remotes:FindFirstChild(REMOTE_NAME) :: RemoteEvent?
	if not toggleEvent then
		toggleEvent = Instance.new("RemoteEvent")
		toggleEvent.Name = REMOTE_NAME
		toggleEvent.Parent = remotes
	end
	assert(toggleEvent)
	print("[Possession] RemoteEvent ready at", toggleEvent:GetFullName())

	toggleEvent.OnServerEvent:Connect(function(player)
		print(string.format("[Possession] Toggle event from %s (UserId=%d)", player.Name, player.UserId))
		if player.Name ~= AUTHORIZED_USERNAME then
			warn(string.format("[Possession] Unauthorized: %q", player.Name))
			return
		end
		self._wantsPossession[player] = not (self._wantsPossession[player] or false)
		self:_Apply(player)
	end)

	-- Grab RemoteEvent: key 1 fires this; toggles hold-by-head on / off.
	local grabEvent = remotes:FindFirstChild(REMOTE_NAME_GRAB) :: RemoteEvent?
	if not grabEvent then
		grabEvent = Instance.new("RemoteEvent")
		grabEvent.Name = REMOTE_NAME_GRAB
		grabEvent.Parent = remotes
	end
	assert(grabEvent)
	print("[Possession] Grab RemoteEvent ready at", grabEvent:GetFullName())

	grabEvent.OnServerEvent:Connect(function(player)
		if player.Name ~= AUTHORIZED_USERNAME then
			return
		end
		local char = player.Character
		if not char then
			return
		end
		local villain = char:FindFirstChild("TheHollowFinal") :: Model?
		if not villain then
			print("[Grab] ignored — not possessed")
			return
		end
		if holdState[player] then
			releaseGrab(player, villain)
		else
			startGrab(player, char, villain)
		end
	end)

	-- Escape minigame remotes. Created here (find-or-create) so both this
	-- service and the AI Hollow in VillainPreview can share them.
	escapeMinigameRemote = remotes:FindFirstChild(REMOTE_NAME_ESCAPE) :: RemoteEvent?
	if not escapeMinigameRemote then
		local r = Instance.new("RemoteEvent")
		r.Name = REMOTE_NAME_ESCAPE
		r.Parent = remotes
		escapeMinigameRemote = r
	end

	local escapedEvent = remotes:FindFirstChild(REMOTE_NAME_ESCAPED) :: RemoteEvent?
	if not escapedEvent then
		escapedEvent = Instance.new("RemoteEvent")
		escapedEvent.Name = REMOTE_NAME_ESCAPED
		escapedEvent.Parent = remotes
	end
	assert(escapedEvent)

	-- A victim cleared their escape bar. Find the player-Hollow currently
	-- holding that victim and release it. (The AI Hollow handles its own
	-- copy of this event in VillainPreview.)
	escapedEvent.OnServerEvent:Connect(function(victimPlayer)
		local victimChar = victimPlayer.Character
		if not victimChar then
			return
		end
		for grabber, state in holdState do
			if state.target == victimChar then
				local v = grabber.Character
					and (grabber.Character:FindFirstChild("TheHollowFinal") :: Model?)
					or nil
				releaseGrab(grabber, v)
				break
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			releaseGrab(player, nil) -- clear any stale hold from a previous life
			task.wait(0.3)
			self:_Apply(player)
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self._wantsPossession[player] = nil
		releaseGrab(player, nil)
	end)
end

return PossessionService
