--!strict
-- Robux ürünleri (Kiomet'te yok; `docs/HESAP_MAGAZA.md`). Yalnız kozmetik ve Credits: güç satılmaz.
-- Kimlikler Creator Hub'da oluşturulunca buraya yazılır. 0 = henüz yok: istemci teklif etmez,
-- sunucu tanımaz. Fiyatlar (Robux) Creator Hub'da ayarlanır; buradaki `robux` yalnız gösterim.
-- Şu anki kimlikler yayın deneyimi `CROWNVIA | Tower Conquest` içindir (2026-11-07). Kimlikler deneyime
-- özeldir: başka deneyimde ürünler yeniden açılıp buraya yazılır.

local Products = {}

export type CreditPack = {
	key: string,
	productId: number,
	credits: number,
	robux: number,
	-- Oyuncu başına bir kez teklif edilir (`ProfileData.oncePacks`).
	once: boolean?,
}
export type Pass = { key: string, passId: number, item: string, robux: number }

Products.CREDIT_PACKS = {
	{ key = "credits_starter", productId = 3729371922, credits = 1000, robux = 49, once = true },
	{ key = "credits_small", productId = 3729372079, credits = 500, robux = 49 },
	{ key = "credits_medium", productId = 3729372322, credits = 1200, robux = 99 },
	{ key = "credits_large", productId = 3729372475, credits = 3000, robux = 199 },
} :: { CreditPack }

-- `key` Catalog'daki `pass` alanıyla aynı.
Products.PASSES = {
	{ key = "gold_banner", passId = 2075091659, item = "gold_banner", robux = 149 },
	{ key = "banner_seal", passId = 2074833701, item = "banner_seal", robux = 149 },
} :: { Pass }

function Products.packByProductId(productId: number): CreditPack?
	if productId == 0 then
		return nil
	end
	for _, pack in Products.CREDIT_PACKS do
		if pack.productId == productId then
			return pack
		end
	end
	return nil
end

function Products.pass(key: string): Pass?
	for _, pass in Products.PASSES do
		if pass.key == key then
			return pass
		end
	end
	return nil
end

return Products
