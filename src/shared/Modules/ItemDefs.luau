--!strict
-- Canonical item registry. Only IDs defined here can exist in player profiles.
-- Server validates inventory mutations against this table.

local Types = require(script.Parent.Types)
type ItemDef = Types.ItemDef
type ItemId = Types.ItemId

local ItemDefs: { [ItemId]: ItemDef } = {
	-- Scrap — common, stacks, used in crafting
	scrap_metal = {
		Id = "scrap_metal",
		DisplayName = "Scrap Metal",
		Kind = "Scrap",
		Stackable = true,
		MaxStack = 99,
		Description = "Twisted iron from the manor's bones.",
	},
	battery = {
		Id = "battery",
		DisplayName = "Dry Battery",
		Kind = "Scrap",
		Stackable = true,
		MaxStack = 99,
		Description = "Somehow still holds a charge.",
	},
	cloth_scrap = {
		Id = "cloth_scrap",
		DisplayName = "Tattered Cloth",
		Kind = "Scrap",
		Stackable = true,
		MaxStack = 99,
		Description = "Smells faintly of lavender and rot.",
	},

	-- Tools — crafted, non-stackable
	flashlight_basic = {
		Id = "flashlight_basic",
		DisplayName = "Flashlight",
		Kind = "Tool",
		Stackable = false,
		MaxStack = 1,
		Description = "Flickers when It is watching.",
	},
	flashlight_upgraded = {
		Id = "flashlight_upgraded",
		DisplayName = "Upgraded Flashlight",
		Kind = "Tool",
		Stackable = false,
		MaxStack = 1,
		Description = "Brighter. Steadier. Slightly.",
	},
	emf_reader = {
		Id = "emf_reader",
		DisplayName = "EMF Reader",
		Kind = "Tool",
		Stackable = false,
		MaxStack = 1,
		Description = "Chirps when the unseen is near.",
	},

	-- Artifacts — the scoring currency, burned at the lobby altar
	cursed_locket = {
		Id = "cursed_locket",
		DisplayName = "Cursed Locket",
		Kind = "Artifact",
		Stackable = false,
		MaxStack = 1,
		Description = "A photograph inside blinks at you.",
		BurnValue = 25,
	},
	bloodied_diary = {
		Id = "bloodied_diary",
		DisplayName = "Bloodied Diary",
		Kind = "Artifact",
		Stackable = false,
		MaxStack = 1,
		Description = "The last page writes itself.",
		BurnValue = 40,
	},
	whispering_doll = {
		Id = "whispering_doll",
		DisplayName = "Whispering Doll",
		Kind = "Artifact",
		Stackable = false,
		MaxStack = 1,
		Description = "It knows your name.",
		BurnValue = 80,
	},
}

local Module = {}

function Module.Get(id: ItemId): ItemDef?
	return ItemDefs[id]
end

function Module.Exists(id: ItemId): boolean
	return ItemDefs[id] ~= nil
end

function Module.All(): { [ItemId]: ItemDef }
	return ItemDefs
end

return Module
