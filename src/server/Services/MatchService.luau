--!strict
-- MatchService: orchestrates the lobby <-> manor run cycle.
-- Handles party formation, descent, match state, and teleport back to lobby.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local GameConfig = require(ReplicatedStorage.Shared.Modules.GameConfig)

export type MatchState = "Idle" | "Intermission" | "Descending" | "Active" | "Ending"

local MatchService = Knit.CreateService({
	Name = "MatchService",
	Client = {
		MatchStateChanged = Knit.CreateSignal(),
		PartyUpdated = Knit.CreateSignal(),
	},

	_state = "Idle" :: MatchState,
	_activePlayers = {} :: { [Player]: true },
})

function MatchService:GetState(): MatchState
	return self._state
end

function MatchService:StartMatch(players: { Player })
	-- TODO: clone map template, spawn GhostService entity, teleport players,
	-- start match timer, listen for all-dead-or-extracted conditions
	assert(#players >= GameConfig.Game.MinPlayersPerMatch, "not enough players")
	self._state = "Descending"
	self.Client.MatchStateChanged:FireAll(self._state)
end

function MatchService:EndMatch(reason: string)
	-- TODO: teleport survivors to lobby, award coins for artifacts still held,
	-- clean up map instance, release Ghost
	self._state = "Idle"
	self.Client.MatchStateChanged:FireAll(self._state)
end

function MatchService:KnitStart() end

return MatchService
