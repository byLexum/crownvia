--!strict
-- Credits kazanımı ve günlük hedefler. Kiomet'te yok: hesap ilerlemesi katmanı (proje kararı,
-- `docs/HESAP_MAGAZA.md`). Savaş kurallarına dokunmaz; sunucu sim durumunu okuyup buraya bildirir.
-- Saf Luau: profil tablosunu değiştirir, olay listesi döner (istemci bildirimi için).
--
--   - Hayat ödülü: hayatın en yüksek skorunun yarısı, hayat başına en fazla LIFE_MAX; gün içinde
--     hayat ödüllerinin toplamı DAILY_CAP'i geçmez (hedef ödülleri hariç).
--   - Günlük 3 hedef (UTC günü): fetih, yükseltme, skor; her biri GOAL_REWARD.
--     Fetih hedefinde aynı kule UTC günü boyunca bir kez sayılır.
--   - Fatih Çerçevesi: FRAME_CAPTURES geçerli fetih (aynı kule aynı hayatta bir kez; hayat kümesini
--     çağıran tutar).
--   - Aktif oynama: hayattayken son ACTIVE_WINDOW saniyede komut veren oyuncunun dakikası sayılır
--     (AFK ödüllendirilmez, belge). Günlük PLAY_MILESTONES Credits verir, PLAY_ITEM_MINUTES toplam
--     dakikada ücretsiz Veteran Crown açılır.
--   - Başarılar: kalıcı hedefler (kral öldür, fetih, yükseltme, skor), her biri bir kez ödül verir.

local ProfileData = require("./ProfileData")

local Rewards = {}

Rewards.LIFE_DIVISOR = 2
Rewards.LIFE_MAX = 100
Rewards.DAILY_CAP = 400
Rewards.GOAL_REWARD = 50
Rewards.FRAME_CAPTURES = 25
Rewards.FRAME_ITEM = "victor_frame"
Rewards.ACTIVE_WINDOW = 120
Rewards.PLAY_MILESTONES = {
	{ minutes = 10, reward = 30 },
	{ minutes = 30, reward = 60 },
	{ minutes = 60, reward = 100 },
}
Rewards.PLAY_ITEM = "veteran_crown"
Rewards.PLAY_ITEM_MINUTES = 300

-- Kral düşürme, intikam (beni öldüreni düşürme), fetih serisi. Seri: COMBO_WINDOW saniye içinde
-- yeni kuleler; basamaklar Credits verir, günlük tavana girer (aynı kule hayatta bir kez sayılır).
Rewards.KING_REWARD = 25
Rewards.REVENGE_REWARD = 50
Rewards.COMBO_WINDOW = 8
Rewards.COMBO_MILESTONES = { [3] = 5, [5] = 10, [10] = 25, [20] = 60 } :: { [number]: number }
-- Serinin 3., 5. ve 7. günündeki sandık: sabit miktar, rastgele değil.
Rewards.STREAK_CHESTS = { [3] = 150, [5] = 300, [7] = 600 } :: { [number]: number }

-- Üst üste oynanan gün ödülü: gün sırasına göre, sonrası son değer.
Rewards.STREAK_REWARDS = { 25, 40, 60, 80, 100, 130, 200 }
-- Haftalık sıralama rozeti (Rankings).
Rewards.CHAMPION_ITEM = "champion_frame"

export type Achievement = { id: string, stat: string, target: number, reward: number }

-- `stat`: kings, captures, upgrades, bestScore (`ProfileData.Stats`).
Rewards.ACHIEVEMENTS = {
	{ id = "kings_1", stat = "kings", target = 1, reward = 50 },
	{ id = "kings_5", stat = "kings", target = 5, reward = 150 },
	{ id = "kings_15", stat = "kings", target = 15, reward = 500 },
	{ id = "kings_50", stat = "kings", target = 50, reward = 1500 },
	{ id = "captures_50", stat = "captures", target = 50, reward = 100 },
	{ id = "captures_250", stat = "captures", target = 250, reward = 300 },
	{ id = "captures_1000", stat = "captures", target = 1000, reward = 1000 },
	{ id = "upgrades_25", stat = "upgrades", target = 25, reward = 100 },
	{ id = "upgrades_100", stat = "upgrades", target = 100, reward = 300 },
	{ id = "score_100", stat = "bestScore", target = 100, reward = 150 },
	{ id = "score_500", stat = "bestScore", target = 500, reward = 500 },
} :: { Achievement }

export type GoalKind = "capture" | "upgrade" | "score"

-- Her tür için hedef seçenekleri; gün ve oyuncuya göre biri seçilir.
local TARGETS: { [string]: { number } } = {
	capture = { 8, 12 },
	upgrade = { 3, 5 },
	score = { 25, 40 },
}
local ORDER: { string } = { "capture", "upgrade", "score" }

export type Event =
	{ kind: "goal", goal: string, target: number, reward: number }
	| {
		kind: "life",
		reward: number,
		score: number,
		towers: number?,
		kings: number?,
		best: number?,
		cutoff: number?,
		seconds: number?,
		nemesis: string?,
		doubled: boolean?,
	}
	| { kind: "streak", count: number, reward: number, chest: number?, day: number? }
	| { kind: "king", reward: number }
	| { kind: "revenge", reward: number }
	| { kind: "combo", count: number, reward: number }
	| { kind: "record", score: number }
	| { kind: "unlock", item: string }
	| { kind: "play", minutes: number, reward: number }
	| { kind: "achievement", id: string, reward: number }

-- UTC gün metni ("2026-11-06").
function Rewards.dayOf(unixTime: number): string
	return os.date("!%Y-%m-%d", unixTime) :: string
end

local function seed(userId: number, day: string): number
	local h = userId % 2147483647
	for i = 1, #day do
		h = (h * 31 + string.byte(day, i)) % 2147483647
	end
	return h
end

-- Gün değiştiyse hedefleri ve günlük sayaçları yenile.
function Rewards.ensureDay(profile: ProfileData.Profile, userId: number, day: string)
	if profile.daily.day == day then
		return
	end
	local s = seed(userId, day)
	local goals: { ProfileData.Goal } = {}
	for i, kind in ORDER do
		local options = TARGETS[kind]
		local pick = (s // (i * 7)) % #options + 1
		table.insert(goals, { kind = kind, target = options[pick], progress = 0, done = false })
	end
	profile.daily = {
		day = day,
		goals = goals,
		earned = 0,
		towers = {},
		minutes = 0,
		firstLife = false,
	}
end

local function advance(
	profile: ProfileData.Profile,
	kind: string,
	progress: number,
	absolute: boolean,
	events: { Event }
)
	for _, goal in profile.daily.goals do
		if goal.kind == kind and not goal.done then
			goal.progress = if absolute
				then math.max(goal.progress, progress)
				else goal.progress + progress
			if goal.progress >= goal.target then
				goal.progress = goal.target
				goal.done = true
				profile.credits += Rewards.GOAL_REWARD
				table.insert(events, {
					kind = "goal",
					goal = kind,
					target = goal.target,
					reward = Rewards.GOAL_REWARD,
				})
			end
		end
	end
end

local function checkAchievements(profile: ProfileData.Profile, events: { Event })
	local stats = profile.stats :: any
	for _, a in Rewards.ACHIEVEMENTS do
		if not profile.achievements[a.id] and (stats[a.stat] or 0) >= a.target then
			profile.achievements[a.id] = true
			profile.credits += a.reward
			table.insert(events, { kind = "achievement", id = a.id, reward = a.reward })
		end
	end
end

-- Oyuncu `count` kral öldürdü.
function Rewards.onKingKill(profile: ProfileData.Profile, count: number): { Event }
	local events: { Event } = {}
	profile.stats.kings += count
	local reward = Rewards.KING_REWARD * count
	profile.credits += reward
	table.insert(events, { kind = "king", reward = reward })
	checkAchievements(profile, events)
	return events
end

-- Beni son öldüren oyuncuyu düşürdüm.
function Rewards.onRevenge(profile: ProfileData.Profile): { Event }
	profile.credits += Rewards.REVENGE_REWARD
	return { { kind = "revenge", reward = Rewards.REVENGE_REWARD } }
end

-- Fetih serisi `count`a ulaştı. İkiden küçükse olay yok.
function Rewards.onCombo(profile: ProfileData.Profile, count: number): { Event }
	if count < 2 then
		return {}
	end
	local reward = Rewards.COMBO_MILESTONES[count] or 0
	reward = math.max(0, math.min(reward, Rewards.DAILY_CAP - profile.daily.earned))
	if reward > 0 then
		profile.credits += reward
		profile.daily.earned += reward
	end
	return { { kind = "combo", count = count, reward = reward } }
end

-- Oyuncu bir kule ele geçirdi. `lifeTowers`: bu hayatta sayılan kuleler (çağıran tutar, hayat
-- bitince sıfırlar).
function Rewards.onCapture(
	profile: ProfileData.Profile,
	towerId: number,
	lifeTowers: { [number]: boolean }
): { Event }
	local events: { Event } = {}
	local key = tostring(towerId)
	if not profile.daily.towers[key] then
		profile.daily.towers[key] = true
		advance(profile, "capture", 1, false, events)
	end
	if not lifeTowers[towerId] then
		lifeTowers[towerId] = true
		profile.stats.captures += 1
		if
			profile.stats.captures >= Rewards.FRAME_CAPTURES
			and not profile.owned[Rewards.FRAME_ITEM]
		then
			profile.owned[Rewards.FRAME_ITEM] = true
			table.insert(events, { kind = "unlock", item = Rewards.FRAME_ITEM })
		end
		checkAchievements(profile, events)
	end
	return events
end

function Rewards.onUpgrade(profile: ProfileData.Profile): { Event }
	local events: { Event } = {}
	advance(profile, "upgrade", 1, false, events)
	profile.stats.upgrades += 1
	checkAchievements(profile, events)
	return events
end

function Rewards.onScore(profile: ProfileData.Profile, score: number): { Event }
	local events: { Event } = {}
	advance(profile, "score", score, true, events)
	profile.stats.bestScore = math.max(profile.stats.bestScore, score)
	checkAchievements(profile, events)
	return events
end

-- Günün ilk girişi (profil hazır olunca): seri ilerler ve ödülü verilir. `yesterday` bir önceki UTC günü.
function Rewards.onDayPlayed(
	profile: ProfileData.Profile,
	day: string,
	yesterday: string
): { Event }
	local events: { Event } = {}
	local streak = profile.streak
	if streak.day == day then
		return events
	end
	local nextCount = if streak.day == yesterday then streak.count + 1 else 1
	profile.streak = { day = day, count = nextCount }
	local list = Rewards.STREAK_REWARDS
	local reward = list[math.min(nextCount, #list)]
	profile.credits += reward
	local weekDay = (nextCount - 1) % 7 + 1
	local chest = Rewards.STREAK_CHESTS[weekDay]
	if chest then
		profile.credits += chest
	end
	table.insert(
		events,
		{ kind = "streak", count = nextCount, reward = reward, chest = chest, day = weekDay }
	)
	return events
end

-- Ölüm ekranı: tamamlanmaya en yakın başarı (oran olarak).
function Rewards.nextGoal(profile: ProfileData.Profile): Achievement?
	local stats = profile.stats :: any
	local best: Achievement? = nil
	local bestRatio = -1
	for _, a in Rewards.ACHIEVEMENTS do
		if not profile.achievements[a.id] then
			local ratio = (stats[a.stat] or 0) / a.target
			if ratio > bestRatio then
				best, bestRatio = a, ratio
			end
		end
	end
	return best
end

-- Oyuncu bir aktif dakikayı tamamladı (sayımı sunucu yapar, `AccountRewards`).
function Rewards.onActiveMinute(profile: ProfileData.Profile): { Event }
	local events: { Event } = {}
	profile.daily.minutes += 1
	profile.stats.activeMinutes += 1
	for _, milestone in Rewards.PLAY_MILESTONES do
		if profile.daily.minutes == milestone.minutes then
			profile.credits += milestone.reward
			table.insert(events, {
				kind = "play",
				minutes = milestone.minutes,
				reward = milestone.reward,
			})
		end
	end
	if
		profile.stats.activeMinutes >= Rewards.PLAY_ITEM_MINUTES
		and not profile.owned[Rewards.PLAY_ITEM]
	then
		profile.owned[Rewards.PLAY_ITEM] = true
		table.insert(events, { kind = "unlock", item = Rewards.PLAY_ITEM })
	end
	return events
end

-- Hayat bitti (kral öldü ya da oyuncu çıktı). `peakScore`: o hayatın en yüksek skoru.
function Rewards.onLifeEnd(profile: ProfileData.Profile, peakScore: number): { Event }
	local events: { Event } = {}
	profile.stats.lives += 1
	profile.stats.bestScore = math.max(profile.stats.bestScore, peakScore)
	local reward = math.min(peakScore // Rewards.LIFE_DIVISOR, Rewards.LIFE_MAX)
	-- Günün ilk oyunu iki katı.
	local doubled = reward > 0 and not profile.daily.firstLife
	if doubled then
		reward *= 2
		profile.daily.firstLife = true
	end
	reward = math.max(0, math.min(reward, Rewards.DAILY_CAP - profile.daily.earned))
	if reward > 0 then
		profile.credits += reward
		profile.daily.earned += reward
	end
	table.insert(events, { kind = "life", reward = reward, score = peakScore, doubled = doubled })
	return events
end

return Rewards
