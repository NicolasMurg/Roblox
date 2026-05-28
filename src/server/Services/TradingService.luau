--!strict
-- TradingService: secure player-to-player trading with double confirmation.
--
-- Flow:
--   1. Host calls RequestTrade(guest) -> server creates session in "Offering"
--   2. Both players add/remove items -> server broadcasts session updates
--   3. Either player calls Confirm() -> their side becomes Confirmed
--   4. When BOTH confirmed, server re-validates ownership and swaps inventories
--   5. Any inventory change during "Confirming" resets both confirmations
--
-- SECURITY: every item must be re-verified against the server profile at
-- commit time. Never trust the snapshot sent from the client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Types = require(ReplicatedStorage.Shared.Modules.Types)

type TradeSession = Types.TradeSession

local TradingService = Knit.CreateService({
	Name = "TradingService",
	Client = {
		TradeInvited = Knit.CreateSignal(),
		SessionUpdated = Knit.CreateSignal(),
		SessionClosed = Knit.CreateSignal(),
	},

	_sessions = {} :: { [string]: TradeSession },
	_playerSession = {} :: { [Player]: string },
})

function TradingService:RequestTrade(host: Player, guest: Player): (boolean, string?)
	if self._playerSession[host] or self._playerSession[guest] then
		return false, "already in a trade"
	end
	local id = HttpService:GenerateGUID(false)
	-- TODO: build TradeSession, store, invite guest
	return true, id
end

function TradingService:UpdateOffer(player: Player, items: any, cosmetics: any): boolean
	-- TODO: mutate session, reset confirmations
	return false
end

function TradingService:Confirm(player: Player): boolean
	-- TODO: mark side confirmed; if both confirmed -> _Commit
	return false
end

function TradingService:Cancel(player: Player)
	-- TODO: close session, refund nothing (no transfer happened)
end

function TradingService:_Commit(sessionId: string)
	-- TODO: re-validate both players own every offered item against DataService;
	-- atomically swap; broadcast SessionClosed with Success=true.
end

function TradingService:KnitStart()
	self._dataService = Knit.GetService("DataService")
end

return TradingService
