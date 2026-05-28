--!strict
-- MovementService: server-authoritative sprint/crouch/stamina.
--
-- Design:
--   * Client sends INTENT only (SetSprinting/SetCrouching). Never a speed value.
--   * Server owns stamina, WalkSpeed, and noise emission to GhostService.
--   * Stamina is streamed back to the client at 5 Hz for the HUD bar — not every
--     frame (would be ~60 packets/sec per player).
--   * While sprinting, the server calls GhostService:ReportSound every 0.5s so
--     the ghost can react to loud players. Silent movement (walk/crouch) emits
--     no sound events.
--
-- Priority when multiple intents are active: Sprint > Crouch > Walk.
-- If stamina reaches 0 the player auto-reverts to walk even if Sprint is held.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local GameConfig = require(ReplicatedStorage.Shared.Modules.GameConfig)

type MoveState = {
	Sprinting: boolean,
	Crouching: boolean,
	Stamina: number,
	NoiseTimer: number,
	BroadcastTimer: number,
	LastBroadcastStamina: number,
}

local STAMINA_BROADCAST_INTERVAL = 0.2 -- 5 Hz
local SPRINT_NOISE_INTERVAL = 0.5 -- 2 Hz

local MovementService = Knit.CreateService({
	Name = "MovementService",
	Client = {
		StaminaChanged = Knit.CreateSignal(),
	},

	_states = {} :: { [Player]: MoveState },
})

-- ===== Internal =====

local function newState(): MoveState
	return {
		Sprinting = false,
		Crouching = false,
		Stamina = GameConfig.Movement.SprintStaminaMax,
		NoiseTimer = 0,
		BroadcastTimer = 0,
		LastBroadcastStamina = GameConfig.Movement.SprintStaminaMax,
	}
end

function MovementService:_GetState(player: Player): MoveState
	local s = self._states[player]
	if not s then
		s = newState()
		self._states[player] = s
	end
	return s
end

function MovementService:_ApplySpeed(player: Player)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	local s = self:_GetState(player)
	if s.Sprinting and s.Stamina > 0 then
		hum.WalkSpeed = GameConfig.Movement.SprintSpeed
	elseif s.Crouching then
		hum.WalkSpeed = GameConfig.Movement.CrouchSpeed
	else
		hum.WalkSpeed = GameConfig.Movement.WalkSpeed
	end
end

function MovementService:_IsMoving(player: Player): boolean
	local char = player.Character
	if not char then return false end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return false end
	-- MoveDirection is zero-vector when the player is standing still.
	return hum.MoveDirection.Magnitude > 0.1
end

-- ===== Public server API =====

function MovementService:GetStamina(player: Player): number
	return self:_GetState(player).Stamina
end

-- ===== Client entry points =====

function MovementService.Client:SetSprinting(player: Player, sprinting: boolean)
	local state = self.Server:_GetState(player)
	state.Sprinting = sprinting == true
	self.Server:_ApplySpeed(player)
end

function MovementService.Client:SetCrouching(player: Player, crouching: boolean)
	local state = self.Server:_GetState(player)
	state.Crouching = crouching == true
	self.Server:_ApplySpeed(player)
end

-- ===== Knit lifecycle =====

function MovementService:KnitInit() end

function MovementService:KnitStart()
	self._ghost = Knit.GetService("GhostService")

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			-- Reset intents on respawn so a player who died mid-sprint doesn't
			-- keep speed on the new character.
			local state = self:_GetState(player)
			state.Sprinting = false
			state.Crouching = false
			state.Stamina = GameConfig.Movement.SprintStaminaMax
			task.wait(0.1) -- let Humanoid finish replication
			self:_ApplySpeed(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._states[player] = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		for player, state in self._states do
			local char = player.Character
			if not char then continue end
			local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not hrp then continue end

			-- Only drain/emit noise if the player is actually moving while
			-- sprint is held. Holding Shift while idle shouldn't cost stamina.
			local actuallySprinting = state.Sprinting and state.Stamina > 0 and self:_IsMoving(player)

			if actuallySprinting then
				state.Stamina = math.max(0, state.Stamina - GameConfig.Movement.SprintStaminaDrainPerSecond * dt)
				if state.Stamina == 0 then
					self:_ApplySpeed(player) -- force walk speed now that stamina is depleted
				end
				state.NoiseTimer -= dt
				if state.NoiseTimer <= 0 then
					state.NoiseTimer = SPRINT_NOISE_INTERVAL
					self._ghost:ReportSound(hrp.Position, GameConfig.Ghost.SprintNoiseRadius)
				end
			else
				state.Stamina = math.min(
					GameConfig.Movement.SprintStaminaMax,
					state.Stamina + GameConfig.Movement.SprintStaminaRegenPerSecond * dt
				)
			end

			state.BroadcastTimer -= dt
			if state.BroadcastTimer <= 0 and math.abs(state.Stamina - state.LastBroadcastStamina) > 0.5 then
				state.BroadcastTimer = STAMINA_BROADCAST_INTERVAL
				state.LastBroadcastStamina = state.Stamina
				self.Client.StaminaChanged:Fire(player, state.Stamina)
			end
		end
	end)
end

return MovementService
