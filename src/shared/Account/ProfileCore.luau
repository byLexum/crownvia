--!strict
-- Profil oturumu: yükle, kaydet, bırak. Kiomet'te yok (bkz. ProfileData.luau).
-- Roblox servislerine dokunmaz: depo (DataStore `UpdateAsync`) ve saat dışarıdan verilir; Lune ile
-- sahte depoyla test edilir. Roblox bağlantısı: `src/server/Profiles.luau`.
--
-- Oturum kilidi (Roblox referans deseni, create.roblox.com/docs/cloud-services/data-stores/
-- player-data-purchasing, 2026-11-06 okundu): kayıtta `lock = { id, time }`, profille aynı
-- `UpdateAsync` içinde yazılır.
--   - Yükleme: kilit yoksa, bu oturumunsa ya da süresi (LOCK_EXPIRY) dolmuşsa alınır; yoksa "locked".
--   - Kayıt: kilit hâlâ bu oturumdaysa yazılır ve tazelenir; değilse "lost" (başka sunucu devraldı),
--     hiçbir şey yazılmaz.
--   - Bırakma: kayıtla birlikte kilit kaldırılır; sonraki sunucu (ör. parti) beklemeden alır.
-- Kayıt aralığı (SAVE_INTERVAL) kilit süresinden çok kısa: sağlıklı oturumun kilidi düşmez.
-- `UpdateAsync` dönüştürücüyü birden fazla kez çağırabilir: dönüştürücü yalnız argümanlarına
-- bakar, sonuç bayrağı her çağrıda baştan kurulur.

local ProfileData = require("./ProfileData")

local ProfileCore = {}

ProfileCore.LOCK_EXPIRY = 600
ProfileCore.SAVE_INTERVAL = 60

export type Store = {
	-- `UpdateAsync` karşılığı: dönüştürücü `nil` dönerse yazılmaz. (başarılı mı, son değer).
	update: (key: string, transform: (old: any) -> any?, userId: number) -> (boolean, any),
}

export type Session = {
	store: Store,
	clock: () -> number,
	id: string,
}

export type LoadResult = "ok" | "locked" | "error"
export type SaveResult = "ok" | "lost" | "error"

function ProfileCore.new(store: Store, clock: () -> number, sessionId: string): Session
	return { store = store, clock = clock, id = sessionId }
end

local function lockHeldByOther(session: Session, record: any, now: number): boolean
	local lock = if type(record) == "table" then record.lock else nil
	if type(lock) ~= "table" or type(lock.id) ~= "string" or type(lock.time) ~= "number" then
		return false
	end
	if lock.id == session.id then
		return false
	end
	return now - lock.time < ProfileCore.LOCK_EXPIRY
end

function ProfileCore.load(
	session: Session,
	key: string,
	userId: number
): (LoadResult, ProfileData.Profile?)
	local result: LoadResult = "error"
	local profile: ProfileData.Profile? = nil
	local ok = session.store.update(key, function(old: any): any?
		local now = session.clock()
		if lockHeldByOther(session, old, now) then
			result = "locked"
			profile = nil
			return nil
		end
		local data = ProfileData.migrate(if type(old) == "table" then old.data else nil)
		if data == nil then
			-- Daha yeni sürümle yazılmış: dokunma.
			result = "locked"
			profile = nil
			return nil
		end
		result = "ok"
		profile = data
		return { data = ProfileData.copy(data), lock = { id = session.id, time = now } }
	end, userId)
	if not ok then
		return "error", nil
	end
	return result, profile
end

-- `release`: kilidi bırak (oyuncu çıktı / sunucu kapanıyor).
function ProfileCore.save(
	session: Session,
	key: string,
	userId: number,
	profile: ProfileData.Profile,
	release: boolean
): SaveResult
	local result: SaveResult = "error"
	local snapshot = ProfileData.copy(profile)
	local ok = session.store.update(key, function(old: any): any?
		local lock = if type(old) == "table" then old.lock else nil
		if type(lock) ~= "table" or lock.id ~= session.id then
			result = "lost"
			return nil
		end
		result = "ok"
		return {
			data = snapshot,
			lock = if release then nil else { id = session.id, time = session.clock() },
		}
	end, userId)
	if not ok then
		return "error"
	end
	return result
end

return ProfileCore
