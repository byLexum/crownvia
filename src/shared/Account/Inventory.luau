--!strict
-- Envanter kuralları: Credits ile satın alma ve kuşanma (Kiomet'te yok; `docs/HESAP_MAGAZA.md`).
-- Saf: profili değiştirir, hata kodu döner. Game Pass sahipliği dışarıdan (`ownsPass`) verilir;
-- sahipliği Roblox tutar, profile yazılmaz.

local Catalog = require("./Catalog")
local ProfileData = require("./ProfileData")

local Inventory = {}

export type OwnsPass = (pass: string) -> boolean

export type Error =
	"UNKNOWN_ITEM"
	| "NOT_FOR_CREDITS"
	| "ALREADY_OWNED"
	| "NOT_ENOUGH_CREDITS"
	| "NOT_OWNED"
	| "BAD_SLOT"

function Inventory.owns(
	profile: ProfileData.Profile,
	item: Catalog.Item,
	ownsPass: OwnsPass
): boolean
	if profile.owned[item.id] then
		return true
	end
	local pass = item.pass
	return pass ~= nil and ownsPass(pass)
end

-- Credits ile satın al. Başarılıysa nil.
function Inventory.buy(profile: ProfileData.Profile, itemId: string, ownsPass: OwnsPass): Error?
	local item = Catalog.get(itemId)
	if item == nil then
		return "UNKNOWN_ITEM"
	end
	local price = item.price
	if price == nil then
		return "NOT_FOR_CREDITS"
	end
	if Inventory.owns(profile, item, ownsPass) then
		return "ALREADY_OWNED"
	end
	if profile.credits < price then
		return "NOT_ENOUGH_CREDITS"
	end
	profile.credits -= price
	profile.owned[item.id] = true
	return nil
end

-- Kuşan. `itemId` nil → yuvayı varsayılana döndür.
function Inventory.equip(
	profile: ProfileData.Profile,
	slot: string,
	itemId: string?,
	ownsPass: OwnsPass
): Error?
	if not Catalog.isSlot(slot) then
		return "BAD_SLOT"
	end
	local equipped = profile.equipped :: { [string]: string? }
	if itemId == nil then
		equipped[slot] = nil
		return nil
	end
	local item = Catalog.get(itemId)
	if item == nil then
		return "UNKNOWN_ITEM"
	end
	if item.slot ~= slot then
		return "BAD_SLOT"
	end
	if not Inventory.owns(profile, item, ownsPass) then
		return "NOT_OWNED"
	end
	equipped[slot] = item.id
	return nil
end

-- Başkalarına yayınlanacak kuşanılanlar: yalnız hâlâ sahip olunanlar (Game Pass iade/silinme,
-- katalogdan kaldırılan ürün).
function Inventory.visible(profile: ProfileData.Profile, ownsPass: OwnsPass): { [string]: string }
	local out: { [string]: string } = {}
	for _, slot in Catalog.SLOTS do
		local id = (profile.equipped :: { [string]: string? })[slot]
		local item = if id then Catalog.get(id) else nil
		if item and item.slot == slot and Inventory.owns(profile, item, ownsPass) then
			out[slot] = item.id
		end
	end
	return out
end

return Inventory
