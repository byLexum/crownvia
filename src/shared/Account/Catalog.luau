--!strict
-- Kozmetik kataloğu (ilk sürüm, `docs/HESAP_MAGAZA.md`). Kiomet'te yok. Yalnız görünüm: hiçbir
-- ürün kural, birim ya da görüş değiştirmez; sahip rengi ve kule silueti sabit kalır.
-- Fiyatlar başlangıç önerisi; yayında ilk Credits ürününe kaç oturumda ulaşıldığı ölçülüp ayarlanır.

local Catalog = {}

export type Slot = "crown" | "capture" | "frame"

export type Item = {
	id: string,
	slot: Slot,
	-- Credits fiyatı (yoksa Credits ile alınamaz).
	price: number?,
	-- Robux Game Pass anahtarı (`src/server/Purchases.luau` kimlikleri; 5. adım).
	pass: string?,
	-- Oyun içi başarıyla açılır (Rewards.FRAME_ITEM).
	unlock: boolean?,
	order: number,
}

local ITEMS: { Item } = {
	{ id = "bronze_seal", slot = "crown", price = 600, order = 1 },
	{ id = "steel_crown", slot = "crown", price = 1500, order = 2 },
	{ id = "gold_banner", slot = "crown", pass = "gold_banner", order = 3 },
	{ id = "veteran_crown", slot = "crown", unlock = true, order = 4 },
	{ id = "signal_crown", slot = "crown", price = 2000, order = 5 },
	{ id = "victory_ring", slot = "capture", price = 900, order = 1 },
	{ id = "banner_seal", slot = "capture", pass = "banner_seal", order = 2 },
	{ id = "chevron_strike", slot = "capture", price = 1200, order = 3 },
	{ id = "star_burst", slot = "capture", price = 1800, order = 4 },
	{ id = "victor_frame", slot = "frame", unlock = true, order = 1 },
	{ id = "iron_frame", slot = "frame", price = 800, order = 2 },
	{ id = "command_frame", slot = "frame", price = 1600, order = 3 },
	{ id = "champion_frame", slot = "frame", unlock = true, order = 4 },
}

local byId: { [string]: Item } = {}
for _, item in ITEMS do
	byId[item.id] = item
end

Catalog.SLOTS = { "crown", "capture", "frame" } :: { Slot }

function Catalog.get(id: string): Item?
	return byId[id]
end

function Catalog.all(): { Item }
	return ITEMS
end

function Catalog.isSlot(value: any): boolean
	return value == "crown" or value == "capture" or value == "frame"
end

return Catalog
