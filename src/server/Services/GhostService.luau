--!strict
-- GhostService: the paranormal entity AI.
-- The ghost is an *invisible anchor* moved by PathfindingService. Its presence
-- is communicated through environmental hazards (flickering lights, slammed
-- doors, thrown objects), NOT a visible rig — until it manifests to jumpscare.
--
-- States:
--   Dormant    -> no target, drifting slowly, ambient whispers only
--   Stalking   -> heard a sound, moves toward it, triggers minor hazards
--   Hunting    -> has a target in sight-line, pathing + major hazards
--   Manifesting-> within ManifestationDistance: fires client jumpscare

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)

local GameConfig = require(ReplicatedStorage.Shared.Modules.GameConfig)

export type GhostState = "Dormant" | "Stalking" | "Hunting" | "Manifesting"

type HazardKind = "LightFlicker" | "DoorSlam" | "ObjectThrow" | "FlashlightOff"

local HAZARD_KINDS: { HazardKind } = { "LightFlicker", "DoorSlam", "ObjectThrow", "FlashlightOff" }

local DRIFT_INTERVAL = 10
local DRIFT_RADIUS = 50
local STALK_REACH_DISTANCE = 3
local PATH_RECOMPUTE_INTERVAL = 1
local PATH_TARGET_DRIFT_THRESHOLD = 5
local LOS_LOST_GRACE_SECONDS = 5
local MANIFEST_DESPAWN_DELAY = 3

local GhostService = Knit.CreateService({
	Name = "GhostService",
	Client = {
		-- Fired to a specific client when the ghost manifests on them.
		Jumpscare = Knit.CreateSignal(),
		-- Broadcast: environmental hazard triggered near a position.
		-- Clients within range play local audio/VFX.
		HazardTriggered = Knit.CreateSignal(),
	},

	_state = "Dormant" :: GhostState,
	_anchor = nil :: BasePart?,
	_target = nil :: Player?,
	_lastHazardAt = 0,
	_lastHeardPosition = nil :: Vector3?,
	_lastHeardAt = 0,
	_lastSeenTargetAt = 0,
	_nextDriftAt = 0,
	_driftTarget = nil :: Vector3?,
	_currentPath = nil :: Path?,
	_currentWaypoints = {} :: { PathWaypoint },
	_currentWaypointIndex = 1,
	_lastPathComputeAt = 0,
	_lastPathTarget = nil :: Vector3?,
	_heartbeatConn = nil :: RBXScriptConnection?,
	StateChanged = Signal.new() :: any,
})

-- ===== Internal helpers =====

function GhostService:_SetState(newState: GhostState)
	if self._state == newState then
		return
	end
	local old = self._state
	self._state = newState
	print(string.format("[Ghost] %s -> %s", old, newState))
	self.StateChanged:Fire(newState)
end

function GhostService:_RandomDriftPoint(origin: Vector3): Vector3
	-- Flat XZ offset — the anchor isn't simulating gravity, we keep it at spawn Y.
	local angle = math.random() * math.pi * 2
	local radius = math.random() * DRIFT_RADIUS
	return origin + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

function GhostService:_HasLineOfSight(fromPos: Vector3, toPos: Vector3): boolean
	local anchor = self._anchor
	if not anchor then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { anchor }
	params.IgnoreWater = true
	local direction = toPos - fromPos
	local distance = direction.Magnitude
	if distance < 0.01 then
		return true
	end
	local result = workspace:Raycast(fromPos, direction, params)
	if not result then
		return true
	end
	-- If the ray hit something, check if it's within the character (same model as target player).
	-- We accept "hit the player's character" as LOS clear.
	local hit = result.Instance
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and hit:IsDescendantOf(char) then
			return true
		end
	end
	return false
end

function GhostService:_FindVisiblePlayerInRadius(radius: number): Player?
	local anchor = self._anchor
	if not anchor then
		return nil
	end
	local anchorPos = anchor.Position
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then continue end
		local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then continue end
		local dist = (hrp.Position - anchorPos).Magnitude
		if dist <= radius and self:_HasLineOfSight(anchorPos, hrp.Position) then
			return player
		end
	end
	return nil
end

function GhostService:_ComputePathTo(targetPos: Vector3)
	local anchor = self._anchor
	if not anchor then
		return
	end
	local path = PathfindingService:CreatePath({
		AgentHeight = 5,
		AgentRadius = 2,
		AgentCanJump = false,
		WaypointSpacing = 4,
	})
	local ok = pcall(function()
		path:ComputeAsync(anchor.Position, targetPos)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		-- Fallback: single waypoint straight at the target. Better to drift than freeze.
		self._currentPath = nil
		self._currentWaypoints = {}
		self._currentWaypointIndex = 1
		self._lastPathComputeAt = os.clock()
		self._lastPathTarget = targetPos
		return
	end
	self._currentPath = path
	self._currentWaypoints = path:GetWaypoints()
	self._currentWaypointIndex = 1
	self._lastPathComputeAt = os.clock()
	self._lastPathTarget = targetPos
end

function GhostService:_StepTowardWaypoint(targetPos: Vector3, speed: number, dt: number)
	local anchor = self._anchor
	if not anchor then
		return
	end

	-- If we have waypoints, prefer advancing toward the next waypoint.
	local stepTarget: Vector3 = targetPos
	if #self._currentWaypoints > 0 and self._currentWaypointIndex <= #self._currentWaypoints then
		local wp = self._currentWaypoints[self._currentWaypointIndex]
		stepTarget = wp.Position
		if (anchor.Position - stepTarget).Magnitude < 1.5 then
			self._currentWaypointIndex += 1
		end
	end

	local delta = stepTarget - anchor.Position
	local mag = delta.Magnitude
	if mag < 0.01 then
		return
	end
	local maxStep = speed * dt
	local step = if mag <= maxStep then delta else delta.Unit * maxStep
	-- Anchored teleport per spec — keep Y locked to anchor's current Y so the ghost
	-- doesn't sink into waypoint geometry (pathfinding waypoints sit on the floor).
	local newPos = anchor.Position + Vector3.new(step.X, 0, step.Z)
	anchor.CFrame = CFrame.new(newPos)
end

function GhostService:_MaybeRepath(targetPos: Vector3)
	local now = os.clock()
	local needsRepath = false
	if not self._lastPathTarget then
		needsRepath = true
	elseif now - self._lastPathComputeAt >= PATH_RECOMPUTE_INTERVAL then
		needsRepath = true
	elseif (self._lastPathTarget - targetPos).Magnitude > PATH_TARGET_DRIFT_THRESHOLD then
		needsRepath = true
	elseif self._currentWaypointIndex > #self._currentWaypoints then
		needsRepath = true
	end
	if needsRepath then
		self:_ComputePathTo(targetPos)
	end
end

function GhostService:_MaybeHazard()
	if self._state ~= "Stalking" and self._state ~= "Hunting" then
		return
	end
	local anchor = self._anchor
	if not anchor then
		return
	end
	local cooldown = GameConfig.Ghost.EnvironmentalHazardCooldown
	if self._state == "Hunting" then
		cooldown = cooldown * 0.5
	end
	if os.clock() - self._lastHazardAt < cooldown then
		return
	end
	local kind = HAZARD_KINDS[math.random(1, #HAZARD_KINDS)]
	-- Bypass TriggerHazard's internal cooldown check by setting _lastHazardAt here;
	-- we honor the *state-scaled* cooldown which may be half the config value.
	self._lastHazardAt = os.clock()
	self.Client.HazardTriggered:FireAll({ Kind = kind, Position = anchor.Position })
end

function GhostService:_Tick(dt: number)
	local anchor = self._anchor
	if not anchor then
		return
	end

	if self._state == "Dormant" then
		local now = os.clock()
		if not self._driftTarget or now >= self._nextDriftAt then
			self._driftTarget = self:_RandomDriftPoint(anchor.Position)
			self._nextDriftAt = now + DRIFT_INTERVAL
			self:_ComputePathTo(self._driftTarget)
		end
		if self._driftTarget then
			self:_MaybeRepath(self._driftTarget)
			self:_StepTowardWaypoint(self._driftTarget, GameConfig.Ghost.PatrolSpeed * 0.5, dt)
		end

	elseif self._state == "Stalking" then
		-- Promote to Hunting if any player is visible within hearing radius.
		local visible = self:_FindVisiblePlayerInRadius(GameConfig.Ghost.HearingRadius)
		if visible then
			self._target = visible
			self._lastSeenTargetAt = os.clock()
			self:_SetState("Hunting")
			self:_ComputePathTo((visible.Character :: Model):WaitForChild("HumanoidRootPart").Position)
		else
			local heard = self._lastHeardPosition
			if heard then
				self:_MaybeRepath(heard)
				self:_StepTowardWaypoint(heard, GameConfig.Ghost.PatrolSpeed, dt)
				if (anchor.Position - heard).Magnitude <= STALK_REACH_DISTANCE then
					self._lastHeardPosition = nil
					self:_SetState("Dormant")
				end
			else
				self:_SetState("Dormant")
			end
		end

	elseif self._state == "Hunting" then
		local target = self._target
		local char = target and target.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not target or not char or not hrp then
			self:_SetState("Dormant")
			self._target = nil
			return
		end
		local targetPos = hrp.Position
		if self:_HasLineOfSight(anchor.Position, targetPos) then
			self._lastSeenTargetAt = os.clock()
		end
		if os.clock() - self._lastSeenTargetAt > LOS_LOST_GRACE_SECONDS then
			self._lastHeardPosition = targetPos
			self._lastHeardAt = os.clock()
			self._target = nil
			self:_SetState("Stalking")
			return
		end
		self:_MaybeRepath(targetPos)
		self:_StepTowardWaypoint(targetPos, GameConfig.Ghost.HuntSpeed, dt)
		if (anchor.Position - targetPos).Magnitude <= GameConfig.Ghost.ManifestationDistance then
			self:ManifestOn(target)
		end
	end

	self:_MaybeHazard()
end

-- ===== Public API =====

function GhostService:Spawn(position: Vector3)
	if self._anchor then
		self:Despawn()
	end
	local anchor = Instance.new("Part")
	anchor.Name = "GhostAnchor"
	anchor.Size = Vector3.new(2, 5, 2)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Massless = true
	-- Anchored=true: we drive position directly via CFrame each tick (spec choice).
	anchor.Anchored = true
	anchor.Position = position
	anchor.Parent = workspace
	self._anchor = anchor

	self._state = "Dormant"
	self._target = nil
	self._lastHeardPosition = nil
	self._driftTarget = nil
	self._nextDriftAt = 0
	self._currentPath = nil
	self._currentWaypoints = {}
	self._currentWaypointIndex = 1
	self._lastPathTarget = nil
	self._lastPathComputeAt = 0
	self._lastHazardAt = 0
end

function GhostService:ReportSound(position: Vector3, loudness: number)
	-- Called by MovementService (sprint), ItemService (dropped item), etc.
	-- `loudness` is an approximate radius in studs the sound carries.
	if not self._anchor then
		return
	end

	local distance = (self._anchor.Position - position).Magnitude
	if distance > loudness then
		return
	end

	if self._state == "Dormant" then
		self:_SetState("Stalking")
	end

	self._lastHeardPosition = position
	self._lastHeardAt = os.clock()
end

function GhostService:TriggerHazard(kind: HazardKind, position: Vector3)
	if os.clock() - self._lastHazardAt < GameConfig.Ghost.EnvironmentalHazardCooldown then
		return
	end
	self._lastHazardAt = os.clock()
	self.Client.HazardTriggered:FireAll({ Kind = kind, Position = position })
end

function GhostService:ManifestOn(player: Player)
	if self._state == "Manifesting" then
		return
	end
	self:_SetState("Manifesting")
	self.Client.Jumpscare:Fire(player)
	task.delay(MANIFEST_DESPAWN_DELAY, function()
		self:Despawn()
	end)
	-- TODO: call MatchService:OnPlayerCaught(player) on next frame
end

function GhostService:Despawn()
	if self._anchor then
		self._anchor:Destroy()
		self._anchor = nil
	end
	self._state = "Dormant"
	self._target = nil
	self._lastHeardPosition = nil
	self._driftTarget = nil
	self._currentPath = nil
	self._currentWaypoints = {}
	self._currentWaypointIndex = 1
	self._lastPathTarget = nil
end

function GhostService:KnitStart()
	self._heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		if not self._anchor then
			return
		end
		self:_Tick(dt)
	end)
end

return GhostService
