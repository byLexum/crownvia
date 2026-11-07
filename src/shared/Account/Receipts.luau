--!strict
-- Developer Product makbuz teslimi (Kiomet'te yok; `docs/HESAP_MAGAZA.md`). Saf karar mantığı:
-- Roblox `ProcessReceipt` aynı makbuzu birden çok kez (oyuncu yeniden girince, başka sunucuda)
-- gönderebilir. Credits ve `PurchaseId` aynı profil yazısında kaydedilir; kayıt başarılı olmadan
-- `PurchaseGranted` dönülmez. Makbuz geçmişi silinmez.
--
-- `pending`: bu sunucuda profile işlenmiş ama henüz kaydedilememiş makbuzlar.

local ProfileData = require("./ProfileData")

local Receipts = {}

export type Decision = "granted" | "notProcessed"

export type SaveResult = "ok" | "lost" | "error"

-- `save`: profili hemen kaydet (Profiles.saveNow). Profil yoksa çağıran "notProcessed" döner.
-- `oncePack`: tek seferlik paketin anahtarı; Credits ile aynı yazıda işaretlenir.
function Receipts.process(
	profile: ProfileData.Profile,
	purchaseId: string,
	credits: number,
	pending: { [string]: boolean },
	save: () -> SaveResult?,
	oncePack: string?
): Decision
	if profile.receipts[purchaseId] and not pending[purchaseId] then
		-- Daha önce verilmiş ve kaydedilmiş.
		return "granted"
	end
	if not profile.receipts[purchaseId] then
		profile.receipts[purchaseId] = true
		profile.credits += credits
		if oncePack then
			profile.oncePacks[oncePack] = true
		end
		pending[purchaseId] = true
	end
	if save() == "ok" then
		pending[purchaseId] = nil
		return "granted"
	end
	-- Kayıt olmadı: Roblox yeniden dener. Credits bellekte kalır, bir sonraki denemede yalnız kayıt
	-- tekrarlanır (iki kez eklenmez). Kilit kaybolduysa bu profil zaten yazılmayacak; başka sunucu
	-- kayıttaki (makbuzsuz) profili yükleyip doğru verir.
	return "notProcessed"
end

return Receipts
