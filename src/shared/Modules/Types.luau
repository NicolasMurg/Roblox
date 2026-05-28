--!strict
-- Shared type definitions used by both client and server.

export type ItemId = string
export type RecipeId = string
export type CosmeticId = string

export type ItemKind = "Scrap" | "Artifact" | "Tool" | "Consumable"

export type ItemDef = {
	Id: ItemId,
	DisplayName: string,
	Kind: ItemKind,
	Stackable: boolean,
	MaxStack: number,
	Description: string,
	BurnValue: number?,
}

export type InventoryEntry = {
	Id: ItemId,
	Count: number,
}

export type CraftingRecipe = {
	Id: RecipeId,
	DisplayName: string,
	Inputs: { InventoryEntry },
	Output: InventoryEntry,
}

export type CosmeticKind = "FlashlightSkin" | "LobbyAura" | "JumpscareAnim"

export type CosmeticDef = {
	Id: CosmeticId,
	DisplayName: string,
	Kind: CosmeticKind,
	RobuxProductId: number?,
}

export type Profile = {
	Coins: number,
	Inventory: { InventoryEntry },
	UnlockedRecipes: { RecipeId },
	OwnedCosmetics: { CosmeticId },
	EquippedCosmetics: { [CosmeticKind]: CosmeticId? },
	Stats: {
		MatchesPlayed: number,
		ArtifactsBurned: number,
		TimesCaught: number,
		TimesEscaped: number,
	},
}

export type TradeOffer = {
	PlayerUserId: number,
	Items: { InventoryEntry },
	Cosmetics: { CosmeticId },
	Confirmed: boolean,
}

export type TradeSession = {
	Id: string,
	Host: TradeOffer,
	Guest: TradeOffer,
	Stage: "Offering" | "Confirming" | "Completed" | "Cancelled",
}

return {}
