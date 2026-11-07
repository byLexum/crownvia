--!strict
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: server/src/service/liveboard_repo.rs (tag 0.1.1)
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: server/src/service.rs

-- Canlı skor tablosu. kodiak `LiveboardRepo::update` → bizde `Liveboard.compute`:
--   - yalnız skoru olan oyuncular (`TowerService::get_score`: hayattaysa `Score::Some(score)`),
--   - botlar kaynakta yalnız geliştirme sürümünde (`LIVEBOARD_BOTS = cfg!(debug_assertions)`); bizde
--     sunucu her zaman `includeBots = true` verir (proje kararı 2026-11-06, kaynaktan sapma: solo ve
--     az oyunculu dünyada tablo boş kalmasın; botlar tabloda "(BOT)" etiketiyle görünür),
--   - skora göre azalan sıra (`sort_by_key(Reverse(score))`, kararlı sıralama; eşitlikte
--     oyuncu kimliği küçük olan önce, kodiak oyuncu listesi sırasının karşılığı),
--   - ilk `LEADERBOARD_SIZE` (10) kişi tabloya, herkese sıra (0 tabanlı) verilir.
-- Saniyede bir hesaplanır (`update_rate_limiter: 1 s`).

local Liveboard = {}

-- `ArenaService::LEADERBOARD_SIZE`
Liveboard.SIZE = 10

export type Entry = { id: number, alias: string, score: number, isBot: boolean }

export type Result = {
	top: { Entry },
	-- Oyuncu kimliği → 0 tabanlı sıra (yalnız skoru olanlar).
	ranks: { [number]: number },
	scores: { [number]: number },
}

export type PlayerView = { alive: boolean, score: number, alias: string, isBot: boolean }

function Liveboard.compute(players: { [number]: PlayerView }, includeBots: boolean): Result
	local pending: { Entry } = {}
	for id, player in players do
		if player.alive and (includeBots or not player.isBot) then
			table.insert(
				pending,
				{ id = id, alias = player.alias, score = player.score, isBot = player.isBot }
			)
		end
	end
	table.sort(pending, function(a: Entry, b: Entry): boolean
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.id < b.id
	end)
	local ranks: { [number]: number } = {}
	local scores: { [number]: number } = {}
	local top: { Entry } = {}
	for rank, entry in pending do
		ranks[entry.id] = math.min(rank - 1, 65535)
		scores[entry.id] = entry.score
		if rank <= Liveboard.SIZE then
			table.insert(top, entry)
		end
	end
	return { top = top, ranks = ranks, scores = scores }
end

return Liveboard
