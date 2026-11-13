-- Robux purchases: Developer Products (Bond Token packs) and Game Passes. Idempotent receipts.
-- IDs live in Shared/Config. Every item here is also earnable by playing (docs/spec.md §8.3).
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local ShopService = {}
local S
local passes: { [Player]: { [string]: boolean } } = {}

function ShopService.getPasses(p: Player)
	return passes[p] or {}
end

local function applyPass(p: Player, key: string)
	local def = Config.GamePasses[key]
	if not def then
		return
	end
	passes[p] = passes[p] or {}
	passes[p][key] = true
	local d = S.Save.get(p)
	if not d then
		return
	end
	if def.bond then
		S.Progress.grantBondPass(p, def.bond)
	end
	if def.cosmetic then
		d.unlocked.cosmetics[def.cosmetic] = true
		S.Save.markDirty(p)
	end
end

local function checkPasses(p: Player)
	for key, def in Config.GamePasses do
		if def.id and def.id ~= 0 then
			local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, p.UserId, def.id)
			if ok and owns then
				applyPass(p, key)
			end
		end
	end
end

local function productById(id: number)
	for key, def in Config.Products do
		if def.id == id and id ~= 0 then
			return key, def
		end
	end
	return nil, nil
end

local function processReceipt(info)
	local p = Players:GetPlayerByUserId(info.PlayerId)
	if not p then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local t0 = os.clock()
	while not S.Save.isLoaded(p) and os.clock() - t0 < 10 do
		task.wait(0.25)
	end
	local d = S.Save.get(p)
	if not d then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if S.Save.hasReceipt(p, info.PurchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local _, def = productById(info.ProductId)
	if not def then
		warn("[Shop] unknown product", info.ProductId)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	d.tokens += def.tokens or 0
	S.Save.addReceipt(p, info.PurchaseId)
	S.Save.markDirty(p)
	-- persist before granting so a crash can't double-grant
	S.Save.save(p)
	S.State.notify(p, "+" .. tostring(def.tokens) .. " Bond Tokens. Thank you!", Config.Colors.Gold)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function ShopService.init(s)
	S = s
end

function ShopService.start()
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(p, passId, bought)
		if not bought then
			return
		end
		for key, def in Config.GamePasses do
			if def.id == passId and passId ~= 0 then
				applyPass(p, key)
				S.State.notify(p, "Unlocked! Thank you for supporting the game.", Config.Colors.Gold)
			end
		end
	end)
	Players.PlayerAdded:Connect(function(p)
		local t0 = os.clock()
		while not S.Save.isLoaded(p) and os.clock() - t0 < 15 do
			task.wait(0.5)
		end
		checkPasses(p)
	end)
	for _, p in Players:GetPlayers() do
		task.spawn(checkPasses, p)
	end
	Players.PlayerRemoving:Connect(function(p)
		passes[p] = nil
	end)
end

return ShopService
