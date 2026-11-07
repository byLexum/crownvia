--!strict
-- Kalıcı oyuncu profili (hesap ilerlemesi, kozmetik envanter). Kiomet'te yok: kaynakta olmayan,
-- savaş kurallarına dokunmayan katman (proje kararı 2026-11-04/06, `docs/HESAP_MAGAZA.md`).
-- Saf Luau: Roblox nesnesine dokunmaz, Lune ile test edilir.

local ProfileData = {}

ProfileData.VERSION = 1

export type Equipped = { crown: string?, capture: string?, frame: string? }

export type Stats = {
	lives: number,
	bestScore: number,
	-- Geçerli fetih sayısı (Fatih Çerçevesi hedefi; aynı kule aynı hayatta bir kez).
	captures: number,
	-- Toplam aktif oynama süresi (dakika; Veteran Crown hedefi).
	activeMinutes: number,
	-- Öldürülen kral ve başarılı yükseltme sayısı (başarılar).
	kings: number,
	upgrades: number,
}

export type Goal = { kind: string, target: number, progress: number, done: boolean }

export type Daily = {
	-- UTC gün ("2026-11-06"); boşsa hedefler henüz kurulmadı.
	day: string,
	goals: { Goal },
	-- Bugün hayat ödülünden kazanılan (günlük tavan; hedef ödülleri hariç).
	earned: number,
	-- Bugün sayılan kuleler (aynı kule UTC günü boyunca bir kez): towerId (string) → true.
	towers: { [string]: boolean },
	-- Bugünkü aktif oynama süresi (dakika).
	minutes: number,
	-- Günün ilk hayat ödülü iki katı verildi mi.
	firstLife: boolean,
}

-- Üst üste oynanan günler (UTC).
export type Streak = { day: string, count: number }

-- Oyuncunun ses tercihi (tek hesap ayarı).
-- Aç/kapa anahtarları ve kaydırıcı düzeyleri (0–1, varsayılan 1).
export type Audio = { music: boolean, sfx: boolean, musicVolume: number, sfxVolume: number }

export type Profile = {
	version: number,
	credits: number,
	owned: { [string]: boolean },
	equipped: Equipped,
	stats: Stats,
	daily: Daily,
	audio: Audio,
	-- Grafik: düşük kalitede süs (ağaç, kaya, kum torbası) çizilmez; zayıf telefonlar için.
	lowGraphics: boolean,
	streak: Streak,
	-- Öğretici bir kez gösterilir; Ayarlar'dan yeniden açılır.
	tutorialDone: boolean,
	-- Alınmış tek seferlik paketler (Products `once`).
	oncePacks: { [string]: boolean },
	-- Ödülü alınmış başarılar.
	achievements: { [string]: boolean },
	-- Teslim edilmiş Robux satın alımları (`PurchaseId`). Silinmez.
	receipts: { [string]: boolean },
}

function ProfileData.default(): Profile
	return {
		version = ProfileData.VERSION,
		credits = 0,
		owned = {},
		equipped = {},
		stats = {
			lives = 0,
			bestScore = 0,
			captures = 0,
			activeMinutes = 0,
			kings = 0,
			upgrades = 0,
		},
		daily = { day = "", goals = {}, earned = 0, towers = {}, minutes = 0, firstLife = false },
		audio = { music = true, sfx = true, musicVolume = 1, sfxVolume = 1 },
		lowGraphics = false,
		streak = { day = "", count = 0 },
		tutorialDone = false,
		oncePacks = {},
		achievements = {},
		receipts = {},
	}
end

local function count(value: any): number
	if type(value) == "number" and value == value and value >= 0 and value < 2 ^ 53 then
		return math.floor(value)
	end
	return 0
end

-- Ses düzeyi: 0–1 arası sayı, geçersizse 1 (NaN dahil).
function ProfileData.level(value: any): number
	if type(value) == "number" and value == value then
		return math.clamp(value, 0, 1)
	end
	return 1
end

local function stringSet(value: any): { [string]: boolean }
	local out: { [string]: boolean } = {}
	if type(value) == "table" then
		for k, v in value do
			if type(k) == "string" and v == true then
				out[k] = true
			end
		end
	end
	return out
end

local function optionalString(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

-- Depodan gelen ham değeri doğrula. Bozuk ya da eksik alan varsayılana döner; bilinen alanlar
-- dışındakiler atılır. Daha yeni sürüm (başka sunucu güncel kodla yazdıysa) olduğu gibi okunmaz:
-- `nil` döner, çağıran profili kilitli gibi davranır (eski kodla yazıp veriyi bozmasın).
function ProfileData.migrate(raw: any): Profile?
	if raw == nil then
		return ProfileData.default()
	end
	if type(raw) ~= "table" then
		return ProfileData.default()
	end
	if type(raw.version) == "number" and raw.version > ProfileData.VERSION then
		return nil
	end
	local p = ProfileData.default()
	p.credits = count(raw.credits)
	p.owned = stringSet(raw.owned)
	if type(raw.equipped) == "table" then
		p.equipped = {
			crown = optionalString(raw.equipped.crown),
			capture = optionalString(raw.equipped.capture),
			frame = optionalString(raw.equipped.frame),
		}
	end
	if type(raw.stats) == "table" then
		p.stats = {
			lives = count(raw.stats.lives),
			bestScore = count(raw.stats.bestScore),
			captures = count(raw.stats.captures),
			activeMinutes = count(raw.stats.activeMinutes),
			kings = count(raw.stats.kings),
			upgrades = count(raw.stats.upgrades),
		}
	end
	local d = raw.daily
	if type(d) == "table" and type(d.day) == "string" then
		local goals: { Goal } = {}
		if type(d.goals) == "table" then
			for _, g in ipairs(d.goals) do
				if type(g) == "table" and type(g.kind) == "string" then
					table.insert(goals, {
						kind = g.kind,
						target = count(g.target),
						progress = count(g.progress),
						done = g.done == true,
					})
				end
			end
		end
		p.daily = {
			day = d.day,
			goals = goals,
			earned = count(d.earned),
			towers = stringSet(d.towers),
			minutes = count(d.minutes),
			firstLife = d.firstLife == true,
		}
	end
	if type(raw.audio) == "table" then
		p.audio = {
			music = raw.audio.music ~= false,
			sfx = raw.audio.sfx ~= false,
			musicVolume = ProfileData.level(raw.audio.musicVolume),
			sfxVolume = ProfileData.level(raw.audio.sfxVolume),
		}
	end
	p.lowGraphics = raw.lowGraphics == true
	if type(raw.streak) == "table" and type(raw.streak.day) == "string" then
		p.streak = { day = raw.streak.day, count = count(raw.streak.count) }
	end
	p.tutorialDone = raw.tutorialDone == true
	p.oncePacks = stringSet(raw.oncePacks)
	p.achievements = stringSet(raw.achievements)
	p.receipts = stringSet(raw.receipts)
	return p
end

-- Derin kopya (depoya yazılan değer bellekteki profille paylaşılmasın).
function ProfileData.copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = ProfileData.copy(v)
	end
	return out
end

return ProfileData
