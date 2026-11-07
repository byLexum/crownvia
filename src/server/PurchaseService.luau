--!strict
-- Robux satın alımları (Kiomet'te yok; `docs/HESAP_MAGAZA.md`).
--   - Credits paketleri (Developer Product): `MarketplaceService.ProcessReceipt`; karar
--     `Receipts.process` (aynı makbuz iki kez verilmez, kayıt olmadan PurchaseGranted dönülmez).
--   - Kozmetik Game Pass'ler: sahiplik oyuncu girince `UserOwnsGamePassAsync` ile sorgulanır,
--     `PromptGamePassPurchaseFinished` ile hemen açılır; profile yazılmaz (sahipliği Roblox tutar).
--   - Satın alma istemi istemciden açılır (`MarketplaceService:Prompt*Purchase`); teslim sunucuda.
-- Kimlikler `src/shared/Account/Products.luau`; 0 olanlar devre dışı.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Account = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Account")
local Products = require(Account:WaitForChild("Products"))
local Receipts = require(Account:WaitForChild("Receipts"))

local Analytics = require(script.Parent.Analytics)
local InventoryService = require(script.Parent.InventoryService)
local Profiles = require(script.Parent.Profiles)

local PurchaseService = {}

type Send = (player: Player, message: { [string]: any }) -> ()

-- Oyuncu → sahip olunan pass anahtarları.
local ownedPasses: { [Player]: { [string]: boolean } } = {}
-- Bu sunucuda işlenmiş ama kaydı bekleyen makbuzlar.
local pending: { [string]: boolean } = {}
local sendRef: Send? = nil

local function passByIdNumber(passId: number): Products.Pass?
	if passId == 0 then
		return nil
	end
	for _, pass in Products.PASSES do
		if pass.passId == passId then
			return pass
		end
	end
	return nil
end

local function loadPasses(player: Player)
	local owned: { [string]: boolean } = {}
	ownedPasses[player] = owned
	for _, pass in Products.PASSES do
		if pass.passId ~= 0 then
			local ok, has = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.passId)
			end)
			if ok and has then
				owned[pass.key] = true
			elseif not ok then
				warn("[robgame] purchases: UserOwnsGamePassAsync failed: " .. tostring(has))
			end
		end
	end
	InventoryService.markDirty()
	-- Profil mesajı (mağazadaki sahiplik) tazelensin.
	Profiles.mutate(player, function() end)
end

-- Paketi profile işle (makbuz başına bir kez) ve bildir. ProcessReceipt ve Studio testi ortak.
local function grant(
	player: Player,
	purchaseId: string,
	pack: Products.CreditPack
): Receipts.Decision
	local profile = Profiles.get(player)
	if profile == nil then
		return "notProcessed"
	end
	local wasNew = not profile.receipts[purchaseId]
	local decision: Receipts.Decision = Receipts.process(
		profile,
		purchaseId,
		pack.credits,
		pending,
		function()
			return Profiles.saveNow(player)
		end,
		if pack.once then pack.key else nil
	)
	if decision == "granted" and wasNew then
		-- İstemcinin profil görünümü tazelensin.
		Profiles.mutate(player, function() end)
		Analytics.economy(
			player,
			true,
			pack.credits,
			profile.credits,
			Enum.AnalyticsEconomyTransactionType.IAP,
			pack.key
		)
		local send = sendRef
		if send then
			send(player, { kind = "PurchaseResult", credits = pack.credits })
		end
	end
	return decision
end

local function processReceipt(info: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	local pack = Products.packByProductId(info.ProductId)
	if pack == nil then
		warn("[robgame] purchases: unknown product " .. tostring(info.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Oyuncu bu sunucuda değilse Roblox sonra (yeniden girince) tekrar dener.
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if grant(player, tostring(info.PurchaseId), pack) == "granted" then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

function PurchaseService.start(send: Send)
	sendRef = send
	InventoryService.setPassChecker(function(player: Player, key: string): boolean
		local owned = ownedPasses[player]
		return owned ~= nil and owned[key] == true
	end)
	Players.PlayerAdded:Connect(function(player)
		task.spawn(loadPasses, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPasses, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		ownedPasses[player] = nil
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local pass = passByIdNumber(passId)
			if not purchased or pass == nil then
				return
			end
			local owned = ownedPasses[player]
			if owned then
				owned[pass.key] = true
			end
			InventoryService.markDirty()
			Profiles.mutate(player, function() end)
			send(player, { kind = "PurchaseResult", item = pass.item })
		end
	)
	MarketplaceService.ProcessReceipt = processReceipt
end

-- Yalnız Studio testi (DevState `buyCredits`): ProcessReceipt ile aynı teslim yolu.
function PurchaseService.devReceipt(player: Player, purchaseId: string, packIndex: number): string
	local pack = Products.CREDIT_PACKS[packIndex]
	if pack == nil then
		return "no pack"
	end
	return grant(player, purchaseId, pack)
end

return PurchaseService
