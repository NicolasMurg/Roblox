--!strict
-- MonetizationService: Robux purchases via MarketplaceService.
-- Currently scoped to: cosmetic crates, cosmetic DevProducts, and game passes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local MonetizationService = Knit.CreateService({
	Name = "MonetizationService",
	Client = {
		PurchaseResult = Knit.CreateSignal(),
	},

	-- Map DevProductId -> handler(player) returning boolean (granted).
	-- Register handlers via :RegisterProduct at Init time.
	_productHandlers = {} :: { [number]: (Player) -> boolean },
})

function MonetizationService:RegisterProduct(productId: number, handler: (Player) -> boolean)
	self._productHandlers[productId] = handler
end

function MonetizationService:PromptPurchase(player: Player, productId: number)
	MarketplaceService:PromptProductPurchase(player, productId)
end

function MonetizationService:KnitInit()
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local player = game.Players:GetPlayerByUserId(receiptInfo.PlayerId)
		if not player then
			-- Retry later when player rejoins; Roblox will re-call ProcessReceipt.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local handler = self._productHandlers[receiptInfo.ProductId]
		if not handler then
			warn("[Monetization] unhandled productId:", receiptInfo.ProductId)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local ok, granted = pcall(handler, player)
		if ok and granted then
			self.Client.PurchaseResult:Fire(player, { ProductId = receiptInfo.ProductId, Success = true })
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
end

function MonetizationService:KnitStart()
	self._dataService = Knit.GetService("DataService")
	-- TODO: register each cosmetic crate / product here via :RegisterProduct
end

return MonetizationService
