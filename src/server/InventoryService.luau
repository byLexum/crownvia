--!strict
-- Envanter komutları ve kozmetik yayını (Kiomet'te yok; `docs/HESAP_MAGAZA.md`).
--   - `BuyItem { item }`: Credits ile satın al. `EquipItem { slot, item? }`: kuşan / varsayılana dön.
--     Sunucuda doğrulanır (profil hazır mı, ürün, sahiplik, bakiye); hız sınırı CommandRemote'ta.
--     Sonuç `{ kind = "InventoryResult", action, item, ok, error? }`.
--   - Her oyuncunun kuşandığı (ve hâlâ sahip olduğu) kozmetikler herkese `{ kind = "Cosmetics",
--     players = { [simId (string)] = { crown?, capture?, frame? } } }` ile gider: değişince, en sık
--     saniyede bir. Yalnız gerçek oyuncular; kozmetik oyun bilgisi taşımaz.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Account = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Account")
local Catalog = require(Account:WaitForChild("Catalog"))
local Inventory = require(Account:WaitForChild("Inventory"))
local ProfileData = require(Account:WaitForChild("ProfileData"))

local Analytics = require(script.Parent.Analytics)
local Profiles = require(script.Parent.Profiles)

local InventoryService = {}

local BROADCAST_PERIOD = 1

type Send = (player: Player, message: { [string]: any }) -> ()

local sendRef: Send? = nil
local handlersRef: { [string]: (Player, { [string]: any }) -> string? } = {}
local dirty = true
local timer = 0
-- Game Pass sahipliği (5. adımda Purchases bağlar). Varsayılan: yok.
local passChecker: (player: Player, pass: string) -> boolean = function(_player, _pass)
	return false
end

local function ownsPassFor(player: Player): Inventory.OwnsPass
	return function(pass: string): boolean
		return passChecker(player, pass)
	end
end

local function result(player: Player, action: string, item: any, err: string?)
	local send = sendRef
	if send then
		send(player, {
			kind = "InventoryResult",
			action = action,
			item = if type(item) == "string" then item else nil,
			ok = err == nil,
			error = err,
		})
	end
end

function InventoryService.setPassChecker(fn: (player: Player, pass: string) -> boolean)
	passChecker = fn
	dirty = true
end

-- Oyuncunun sahip olduğu Game Pass anahtarları (profil mesajı; mağaza ekranı için).
function InventoryService.ownedPasses(player: Player): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, item in Catalog.all() do
		local pass = item.pass
		if pass and passChecker(player, pass) then
			out[pass] = true
		end
	end
	return out
end

-- Sahiplik dışarıda değişti (Game Pass satın alındı): yayını tazele.
function InventoryService.markDirty()
	dirty = true
end

-- Komut işleyicileri (main.server handlers tablosuna eklenir).
function InventoryService.start(send: Send): { [string]: (Player, { [string]: any }) -> string? }
	sendRef = send
	Profiles.changed:Connect(function()
		dirty = true
	end)
	handlersRef = {
		SetAudio = function(player: Player, payload): string?
			if type(payload.music) ~= "boolean" or type(payload.sfx) ~= "boolean" then
				return "malformed command"
			end
			if type(payload.musicVolume) ~= "number" or type(payload.sfxVolume) ~= "number" then
				return "malformed command"
			end
			if Profiles.get(player) == nil then
				return "profile not ready"
			end
			Profiles.mutate(player, function(profile)
				profile.audio = {
					music = payload.music,
					sfx = payload.sfx,
					musicVolume = ProfileData.level(payload.musicVolume),
					sfxVolume = ProfileData.level(payload.sfxVolume),
				}
			end)
			return nil
		end,
		-- Grafik kalitesi (düşük: süs çizilmez).
		SetGraphics = function(player: Player, payload): string?
			if type(payload.low) ~= "boolean" then
				return "malformed command"
			end
			if Profiles.get(player) == nil then
				return "profile not ready"
			end
			Profiles.mutate(player, function(profile)
				profile.lowGraphics = payload.low
			end)
			return nil
		end,
		-- Öğretici tamamlandı (true) ya da Ayarlar'dan yeniden istendi (false).
		SetTutorialDone = function(player: Player, payload): string?
			if type(payload.done) ~= "boolean" then
				return "malformed command"
			end
			if Profiles.get(player) == nil then
				return "profile not ready"
			end
			Profiles.mutate(player, function(profile)
				profile.tutorialDone = payload.done
			end)
			return nil
		end,
		ShopStep = function(player: Player, payload): string?
			local step = payload.step
			if type(step) ~= "number" or step ~= math.floor(step) or step < 1 or step > 3 then
				return "malformed command"
			end
			Analytics.shop(player, step)
			return nil
		end,
		BuyItem = function(player: Player, payload): string?
			local itemId = payload.item
			if type(itemId) ~= "string" or #itemId > 64 then
				return "malformed command"
			end
			if Profiles.get(player) == nil then
				result(player, "buy", itemId, "PROFILE_NOT_READY")
				return "profile not ready"
			end
			local err: string? = nil
			local spent, balance = 0, 0
			Profiles.mutate(player, function(profile)
				local before = profile.credits
				err = Inventory.buy(profile, itemId, ownsPassFor(player))
				spent, balance = before - profile.credits, profile.credits
			end)
			if err == nil then
				Analytics.economy(
					player,
					false,
					spent,
					balance,
					Enum.AnalyticsEconomyTransactionType.Shop,
					itemId
				)
				Analytics.shop(player, 4)
			end
			result(player, "buy", itemId, err)
			return err
		end,
		EquipItem = function(player: Player, payload): string?
			local slot = payload.slot
			local itemId = payload.item
			if
				not Catalog.isSlot(slot)
				or (itemId ~= nil and (type(itemId) ~= "string" or #itemId > 64))
			then
				return "malformed command"
			end
			if Profiles.get(player) == nil then
				result(player, "equip", itemId, "PROFILE_NOT_READY")
				return "profile not ready"
			end
			local err: string? = nil
			Profiles.mutate(player, function(profile)
				err = Inventory.equip(profile, slot, itemId, ownsPassFor(player))
			end)
			result(player, "equip", itemId, err)
			return err
		end,
	}
	return handlersRef
end

-- Yalnız Studio test komutu (DevState `inv`): istemci komutuyla aynı işleyici.
function InventoryService.devRun(player: Player, kind: string, payload: { [string]: any }): string?
	local handler = handlersRef[kind]
	return if handler then handler(player, payload) else "unknown"
end

-- Her kare (main.server Heartbeat). Oyuncu girince/çıkınca da yayın tazelenir.
function InventoryService.step(simIds: { [Player]: number }, dt: number)
	timer += dt
	if not dirty or timer < BROADCAST_PERIOD then
		return
	end
	timer = 0
	dirty = false
	local send = sendRef
	if send == nil then
		return
	end
	local players: { [string]: { [string]: string } } = {}
	for player, simId in simIds do
		local profile = Profiles.get(player)
		if profile then
			players[tostring(simId)] = Inventory.visible(profile, ownsPassFor(player))
		end
	end
	for player in simIds do
		send(player, { kind = "Cosmetics", players = players })
	end
end

return InventoryService
