--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: server/src/bot.rs (BotOptions)
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: server/src/service/bot_repo.rs, server/src/service/scene_repo.rs (tag 0.1.1)

-- kodiak `BotRepo` (bot sayısı, katılma/ayrılma, her tick karar + komut) → bizde bu modül.
-- Saf Luau: Studio dışında Lune ile test edilir. Sunucu yalnızca `BotRepo.step` çağırır.
--
-- Sapma (kural değil): kodiak bot yuvaları sabit `PlayerId::nth_bot(i)` id'leri kullanır ve
-- ayrılan bot aynı id ile geri gelir. Bizde ayrılan bot `Game.playerQuit` ile silinir, yeni
-- bot yeni id alır. Oyun kurallarına etkisi yok.

local Bot = require("./Bot")
local Game = require("./Game")

type Game = Game.Game

type Slot = {
	playerId: number,
	bot: Bot.Bot,
	-- Yalnız güncelleme döngüsü içinde dolu (`action_buffer`).
	action: Bot.Action?,
}

export type BotRepo = {
	slots: { Slot },
	-- `EngineArenaSettings::bots`: nil → otomatik (oyuncu sayısına göre).
	fixedCount: number?,
	-- `EngineArenaSettings::bot_aggression` (0..10, varsayılan 1).
	aggression: number,
	-- Bot sayısının üst sınırı. Kaynakta `Bot.MAX_BOTS` (200); Roblox'ta ölçümle düşürülebilir.
	maxBots: number,
	rng: () -> number,
	-- Reddedilen bot komutu sayısı (ölçüm için). Kaynakta bot komut hataları sessizce yutulur.
	lastErrors: number,
}

local BotRepo = {}

function BotRepo.new(rng: () -> number): BotRepo
	return {
		slots = {},
		fixedCount = nil,
		aggression = 1,
		maxBots = Bot.MAX_BOTS,
		rng = rng,
		lastErrors = 0,
	}
end

function BotRepo.count(repo: BotRepo): number
	return #repo.slots
end

-- `BotRepo::set_count`: tick başına en fazla `max(4, count / 50)` bot eklenir ya da çıkarılır.
local function setCount(repo: BotRepo, game: Game, count: number)
	local governor = math.max(4, count // 50)

	while count < #repo.slots and governor > 0 do
		governor -= 1
		local slot = table.remove(repo.slots) :: Slot
		Game.playerQuit(game, slot.playerId)
	end

	while count > #repo.slots and governor > 0 do
		governor -= 1
		local playerId = Game.playerJoined(game, true)
		table.insert(repo.slots, { playerId = playerId, bot = Bot.new(repo.rng), action = nil })
	end
end

-- `BotRepo::update_count`: gerçek (canlı) oyuncu sayısına göre hedef bot sayısı.
function BotRepo.updateCount(repo: BotRepo, game: Game, realPlayersLive: number)
	local count = repo.fixedCount
	if count == nil then
		local auto = Bot.BOT_PERCENT * realPlayersLive // 100
		count = math.clamp(auto, math.min(Bot.MIN_BOTS, repo.maxBots), repo.maxBots)
	end
	setCount(repo, game, count :: number)
end

-- `BotRepo::update`: her bot için bir karar (komut henüz uygulanmaz).
function BotRepo.update(repo: BotRepo, game: Game)
	for _, slot in repo.slots do
		slot.action = Bot.update(slot.bot, game, slot.playerId, repo.rng, repo.aggression)
	end
end

-- Ana menü arkası canlı dünya: izlenecek bot. Mevcut hedef yaşıyorsa korunur (kamera atlamasın),
-- yoksa skoru en yüksek canlı bot. Yalnız bot izlenir: menüden gerçek oyuncu gözetlenemez.
function BotRepo.spectateTarget(repo: BotRepo, game: Game, current: number?): number?
	local best: number? = nil
	local bestScore = -1
	for _, slot in repo.slots do
		local data = game.players[slot.playerId]
		if data ~= nil and data.alive then
			if slot.playerId == current then
				return current
			end
			if data.score > bestScore then
				best, bestScore = slot.playerId, data.score
			end
		end
	end
	return best
end

-- `BotRepo::post_update`: kararlar `Game.post_update`'ten sonra uygulanır.
function BotRepo.postUpdate(repo: BotRepo, game: Game)
	for _, slot in repo.slots do
		local action = slot.action
		slot.action = nil
		if action == nil then
			continue
		end
		if action.kind == "Command" then
			-- Kaynakta bot komut hataları loglanmaz (`if !player.is_bot()`).
			if Game.command(game, slot.playerId, action.command) ~= nil then
				repo.lastErrors += 1
			end
		elseif action.kind == "Quit" then
			-- Geri dönüşüm: aynı yuvada yeni bot.
			Game.botQuit(game, slot.playerId)
			slot.bot = Bot.new(repo.rng)
		end
	end
end

-- kodiak `SceneRepo::update` sırası: bot sayısı → `tick` → bot kararları → `post_update` → bot komutları.
-- İnsan oyuncu komutları bu çağrıdan önce (RemoteEvent ile) uygulanmış olur.
function BotRepo.step(repo: BotRepo, game: Game, realPlayersLive: number)
	BotRepo.updateCount(repo, game, realPlayersLive)
	Game.tick(game)
	BotRepo.update(repo, game)
	Game.postUpdate(game)
	BotRepo.postUpdate(repo, game)
end

return table.freeze(BotRepo)
