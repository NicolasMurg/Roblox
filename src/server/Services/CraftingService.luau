--!strict
-- CraftingService: server-authoritative crafting + artifact burning.
-- ALL crafting validation happens here. Clients only send a RecipeId.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Knit = require(ReplicatedStorage.Packages.Knit)

local CraftingRecipes = require(ReplicatedStorage.Shared.Modules.CraftingRecipes)
local ItemDefs = require(ReplicatedStorage.Shared.Modules.ItemDefs)
local GameConfig = require(ReplicatedStorage.Shared.Modules.GameConfig)

local CraftingService = Knit.CreateService({
	Name = "CraftingService",
	Client = {
		CraftResult = Knit.CreateSignal(),
	},
})

function CraftingService:KnitInit()
	self._dataService = nil
end

function CraftingService:KnitStart()
	self._dataService = Knit.GetService("DataService")
end

-- Validates recipe + player inventory, consumes inputs, grants output.
-- Returns (success, reason).
function CraftingService:Craft(player: Player, recipeId: string): (boolean, string?)
	local recipe = CraftingRecipes.Get(recipeId)
	if not recipe then
		return false, "unknown recipe"
	end

	local profile = self._dataService:GetProfile(player)
	if not profile then
		return false, "profile not loaded"
	end

	if not table.find(profile.UnlockedRecipes, recipeId) then
		return false, "recipe not unlocked"
	end

	-- Count current inventory
	local owned: { [string]: number } = {}
	for _, entry in profile.Inventory do
		owned[entry.Id] = (owned[entry.Id] or 0) + entry.Count
	end

	-- Check every input
	for _, input in recipe.Inputs do
		if (owned[input.Id] or 0) < input.Count then
			return false, "missing " .. input.Id
		end
	end

	-- Consume inputs atomically. If any removal fails, we've already checked
	-- counts above so this shouldn't happen, but guard anyway.
	for _, input in recipe.Inputs do
		local ok = self._dataService:RemoveItem(player, input.Id, input.Count)
		if not ok then
			return false, "inventory state changed mid-craft"
		end
	end

	local ok, reason = self._dataService:AddItem(player, recipe.Output.Id, recipe.Output.Count)
	if not ok then
		return false, reason or "could not grant output"
	end

	self.Client.CraftResult:Fire(player, { Success = true, RecipeId = recipeId })
	return true
end

function CraftingService:BurnArtifact(player: Player, itemId: string): (boolean, string?)
	local def = ItemDefs.Get(itemId)
	if not def or def.Kind ~= "Artifact" then
		return false, "not an artifact"
	end

	local removed = self._dataService:RemoveItem(player, itemId, 1)
	if not removed then
		return false, "artifact not in inventory"
	end

	local reward = def.BurnValue or GameConfig.Economy.ArtifactBurnRewardCoins
	self._dataService:AddCoins(player, reward)
	self._dataService:IncrementStat(player, "ArtifactsBurned", 1)
	return true
end

-- Client-exposed entry point. Clients send a RecipeId; server validates.
function CraftingService.Client:Craft(player: Player, recipeId: string)
	return self.Server:Craft(player, recipeId)
end

function CraftingService.Client:BurnArtifact(player: Player, itemId: string)
	return self.Server:BurnArtifact(player, itemId)
end

return CraftingService
