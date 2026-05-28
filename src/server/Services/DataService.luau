--!strict
-- DataService: the single source of truth for all persistent player state.
-- Every other server service that reads or mutates a player's profile MUST go
-- through this service. Never touch DataStores directly elsewhere.
--
-- Wraps ProfileService (by loleris). Profiles are loaded on PlayerAdded,
-- released on PlayerRemoving, and auto-save on ProfileService's own cadence.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)

local ProfileStoreModule = require(ServerScriptService.ServerPackages.ProfileStore)

local Shared = ReplicatedStorage.Shared.Modules
local GameConfig = require(Shared.GameConfig)
local ProfileTemplate = require(Shared.ProfileTemplate)
local Types = require(Shared.Types)
local ItemDefs = require(Shared.ItemDefs)

type Profile = Types.Profile
type InventoryEntry = Types.InventoryEntry
type ItemId = Types.ItemId

-- ProfileStore (the successor to ProfileService, same author) auto-saves on its
-- own cadence. `.Mock` is used in Studio without API access so we don't clobber
-- live data during local iteration.
local PlayerStore = ProfileStoreModule.New(GameConfig.DataStore.ProfileStoreName, ProfileTemplate)
if RunService:IsStudio() then
	PlayerStore = PlayerStore.Mock
end

local DataService = Knit.CreateService({
	Name = "DataService",

	-- Client-exposed API (read-only). Writes go through gameplay services.
	Client = {
		ProfileReady = Knit.CreateSignal(),
		ProfileUpdated = Knit.CreateSignal(),
	},

	-- Internal state
	_profiles = {} :: { [Player]: any },
	ProfileLoaded = Signal.new() :: any,
	ProfileReleased = Signal.new() :: any,
})

-- ===== Internal helpers =====

local function deepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value :: any) do
		copy[k] = deepCopy(v)
	end
	return copy :: any
end

function DataService:_LoadProfile(player: Player)
	local profile = PlayerStore:StartSessionAsync("Player_" .. player.UserId, {
		Cancel = function()
			return not player:IsDescendantOf(Players)
		end,
	})

	if not profile then
		-- Another server still holds the session and we couldn't steal it, or
		-- the player left mid-load. Kick to retry.
		player:Kick("Profile could not be loaded. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile() -- adds new template fields to older profiles

	profile.OnSessionEnd:Connect(function()
		self._profiles[player] = nil
		self.ProfileReleased:Fire(player)
		if player:IsDescendantOf(Players) then
			player:Kick("Session ended. Please rejoin.")
		end
	end)

	if not player:IsDescendantOf(Players) then
		-- Player left before load finished.
		profile:EndSession()
		return
	end

	self._profiles[player] = profile
	self.ProfileLoaded:Fire(player, profile.Data)
	self.Client.ProfileReady:Fire(player, deepCopy(profile.Data))
end

function DataService:_ReleaseProfile(player: Player)
	local profile = self._profiles[player]
	if profile then
		profile:EndSession()
	end
end

-- ===== Public API (server-side) =====

-- Returns the raw Profile.Data table (mutate in place; ProfileService auto-saves).
-- Returns nil if profile hasn't finished loading yet.
function DataService:GetProfile(player: Player): Profile?
	local profile = self._profiles[player]
	return if profile then profile.Data else nil
end

-- Awaits the profile to load, up to `timeout` seconds (default 30).
function DataService:WaitForProfile(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 30)
	while os.clock() < deadline do
		local data = self:GetProfile(player)
		if data then
			return data
		end
		if not player:IsDescendantOf(Players) then
			return nil
		end
		task.wait(0.1)
	end
	return nil
end

-- Adds `count` of `itemId` to the player's inventory.
-- Returns true on success, false + reason if validation fails.
function DataService:AddItem(player: Player, itemId: ItemId, count: number): (boolean, string?)
	if count <= 0 then
		return false, "count must be positive"
	end
	if not ItemDefs.Exists(itemId) then
		return false, "unknown item: " .. tostring(itemId)
	end

	local profile = self:GetProfile(player)
	if not profile then
		return false, "profile not loaded"
	end

	local def = ItemDefs.Get(itemId) :: any

	if def.Stackable then
		for _, entry in profile.Inventory do
			if entry.Id == itemId and entry.Count < def.MaxStack then
				local space = def.MaxStack - entry.Count
				local take = math.min(space, count)
				entry.Count += take
				count -= take
				if count == 0 then
					self:_Broadcast(player)
					return true
				end
			end
		end
	end

	while count > 0 do
		local take = if def.Stackable then math.min(def.MaxStack, count) else 1
		table.insert(profile.Inventory, { Id = itemId, Count = take })
		count -= take
	end

	self:_Broadcast(player)
	return true
end

-- Removes `count` of `itemId`. Returns true + actually removed, or false if
-- the player doesn't have enough. Atomic: removes all-or-nothing.
function DataService:RemoveItem(player: Player, itemId: ItemId, count: number): boolean
	if count <= 0 then
		return false
	end

	local profile = self:GetProfile(player)
	if not profile then
		return false
	end

	local total = 0
	for _, entry in profile.Inventory do
		if entry.Id == itemId then
			total += entry.Count
		end
	end
	if total < count then
		return false
	end

	local remaining = count
	local i = 1
	while i <= #profile.Inventory and remaining > 0 do
		local entry = profile.Inventory[i]
		if entry.Id == itemId then
			if entry.Count <= remaining then
				remaining -= entry.Count
				table.remove(profile.Inventory, i)
			else
				entry.Count -= remaining
				remaining = 0
				i += 1
			end
		else
			i += 1
		end
	end

	self:_Broadcast(player)
	return true
end

function DataService:AddCoins(player: Player, amount: number): boolean
	if amount == 0 then
		return true
	end
	local profile = self:GetProfile(player)
	if not profile then
		return false
	end
	profile.Coins = math.max(0, profile.Coins + amount)
	self:_Broadcast(player)
	return true
end

function DataService:GrantCosmetic(player: Player, cosmeticId: string): boolean
	local profile = self:GetProfile(player)
	if not profile then
		return false
	end
	if table.find(profile.OwnedCosmetics, cosmeticId) then
		return true -- already owned; idempotent
	end
	table.insert(profile.OwnedCosmetics, cosmeticId)
	self:_Broadcast(player)
	return true
end

function DataService:IncrementStat(player: Player, statName: string, delta: number)
	local profile = self:GetProfile(player)
	if not profile then
		return
	end
	local stats = profile.Stats :: any
	stats[statName] = (stats[statName] or 0) + delta
	self:_Broadcast(player)
end

function DataService:_Broadcast(player: Player)
	local profile = self:GetProfile(player)
	if profile then
		self.Client.ProfileUpdated:Fire(player, deepCopy(profile))
	end
end

-- ===== Client-exposed methods =====

function DataService.Client:GetProfile(player: Player): Profile?
	local profile = self.Server:GetProfile(player)
	return if profile then deepCopy(profile) else nil
end

-- ===== Knit lifecycle =====

function DataService:KnitInit()
	Players.PlayerAdded:Connect(function(player)
		self:_LoadProfile(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_ReleaseProfile(player)
	end)

	-- Handle players already in-game when the script first runs (edge case).
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_LoadProfile(player)
		end)
	end

	-- End every session on server shutdown so ProfileStore can flush saves.
	game:BindToClose(function()
		for _, profile in self._profiles do
			profile:EndSession()
		end
		-- Give ProfileStore a moment to flush; BindToClose has 30s budget.
		if RunService:IsStudio() then
			task.wait(0.1)
		else
			task.wait(2)
		end
	end)
end

return DataService
