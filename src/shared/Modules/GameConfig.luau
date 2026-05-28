--!strict
-- Central tuning knobs for Marvin's Dense Forest.
-- Keep gameplay balance in one place so designers can iterate without touching services.

local GameConfig = {}

GameConfig.Game = {
	Title = "Marvin's Dense Forest",
	MinPlayersPerMatch = 1,
	MaxPlayersPerMatch = 6,
	MatchIntermissionSeconds = 20,
	MatchLengthSeconds = 480,
}

GameConfig.Lobby = {
	SpawnPosition = Vector3.new(0, 5, 0),
	AltarPosition = Vector3.new(0, 5, -15),
	SafeRadius = 120,
}

GameConfig.Movement = {
	WalkSpeed = 14,
	SprintSpeed = 22,
	CrouchSpeed = 7,
	SprintStaminaMax = 100,
	SprintStaminaDrainPerSecond = 18,
	SprintStaminaRegenPerSecond = 10,
	JumpPower = 42,
}

GameConfig.Ghost = {
	PatrolSpeed = 10,
	HuntSpeed = 20,
	Aggression_Idle = 0,
	Aggression_Hunting = 1,
	HearingRadius = 40,
	SprintNoiseRadius = 60,
	ManifestationDistance = 8,
	EnvironmentalHazardCooldown = 12,
}

GameConfig.Flashlight = {
	DefaultBatteryMax = 100,
	DefaultBatteryDrainPerSecond = 1.5,
	FlickerChancePerSecondNearGhost = 0.25,
}

GameConfig.Economy = {
	StartingCoins = 0,
	ArtifactBurnRewardCoins = 25,
	CrateCostRobux = 99,
}

GameConfig.DataStore = {
	ProfileStoreName = "MarvinPlayerData_v1",
	AutoSaveIntervalSeconds = 30,
}

return GameConfig
