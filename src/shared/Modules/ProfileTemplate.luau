--!strict
-- Default profile shape handed to new players.
-- ProfileService reconciles existing profiles against this template, so ADDING
-- new fields is safe. RENAMING or removing fields is NOT — migrate explicitly.

local Types = require(script.Parent.Types)
type Profile = Types.Profile

local Template: Profile = {
	Coins = 0,
	Inventory = {},
	UnlockedRecipes = { "flashlight_basic" },
	OwnedCosmetics = {},
	EquippedCosmetics = {},
	Stats = {
		MatchesPlayed = 0,
		ArtifactsBurned = 0,
		TimesCaught = 0,
		TimesEscaped = 0,
	},
}

return Template
