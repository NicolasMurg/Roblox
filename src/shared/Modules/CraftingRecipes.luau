--!strict
-- Authoritative recipe list. Server validates every craft against this.
-- Never trust a client-submitted recipe — always look up by RecipeId here.

local Types = require(script.Parent.Types)
type CraftingRecipe = Types.CraftingRecipe
type RecipeId = Types.RecipeId

local Recipes: { [RecipeId]: CraftingRecipe } = {
	flashlight_basic = {
		Id = "flashlight_basic",
		DisplayName = "Flashlight",
		Inputs = {
			{ Id = "scrap_metal", Count = 2 },
			{ Id = "battery", Count = 1 },
		},
		Output = { Id = "flashlight_basic", Count = 1 },
	},
	flashlight_upgraded = {
		Id = "flashlight_upgraded",
		DisplayName = "Upgraded Flashlight",
		Inputs = {
			{ Id = "flashlight_basic", Count = 1 },
			{ Id = "scrap_metal", Count = 3 },
			{ Id = "battery", Count = 1 },
		},
		Output = { Id = "flashlight_upgraded", Count = 1 },
	},
	emf_reader = {
		Id = "emf_reader",
		DisplayName = "EMF Reader",
		Inputs = {
			{ Id = "scrap_metal", Count = 4 },
			{ Id = "battery", Count = 2 },
			{ Id = "cloth_scrap", Count = 2 },
		},
		Output = { Id = "emf_reader", Count = 1 },
	},
}

local Module = {}

function Module.Get(id: RecipeId): CraftingRecipe?
	return Recipes[id]
end

function Module.All(): { [RecipeId]: CraftingRecipe }
	return Recipes
end

return Module
