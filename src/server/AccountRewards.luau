--!strict
-- Hesap ödüllerini sim durumundan çıkarır (Kiomet'te yok; `docs/HESAP_MAGAZA.md`). Simülasyonu
-- yalnız OKUR: her adımdan sonra gerçek oyuncuların kule kümesi, skoru ve hayatta olup olmadığı.
--   - Fetih: önceki adımda olmayan kule kümede belirdi (doğuştaki ilk kule hariç).
--   - Yükseltme: Upgrade komutu başarılı (main.server bildirir).
--   - Hayat sonu: `alive` true → false ya da oyuncu çıkışı (Profiles kancası, kayıttan önce).
-- Profil hazır değilse olay yok sayılır (o hayatın ödülü verilmez, bkz. belge).
-- İstemciye: `Profile` (değişince, en sık saniyede bir) ve `Reward` (olay bildirimi).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Game = require(Shared:WaitForChild("Sim"):WaitForChild("Game"))
local Rewards = require(Shared:WaitForChild("Account"):WaitForChild("Rewards"))

local Analytics = require(script.Parent.Analytics)
local InventoryService = require(script.Parent.InventoryService)
local Profiles = require(script.Parent.Profiles)
local Rankings = require(script.Parent.Rankings)

local AccountRewards = {}

local PROFILE_SEND_PERIOD = 1

type Tracker = {
	alive: boolean,
	-- Bu oturumda başlayan hayat sayısı (analitik: yeniden oynama).
	lives: number,
	peak: number,
	-- Bu hayatta Fatih Çerçevesi sayacına girmiş kuleler.
	lifeTowers: { [number]: boolean },
	-- Önceki adımdaki kule kümesi.
	known: { [number]: boolean },
	-- Sim sayacının son görülen değeri (öldürülen krallar).
	kings: number,
	-- Ölüm özeti: bu hayatın en büyük kule sayısı ve öldürülen kralları.
	peakTowers: number,
	lifeKings: number,
	-- Bu hayatın başındaki rekor, rekor kutlandı mı, hayat başlangıcı.
	bestAtStart: number,
	recordFired: boolean,
	startedAt: number,
	-- Fetih serisi.
	combo: number,
	comboAt: number,
	-- Beni son öldüren (intikam).
	nemesisId: number?,
	nemesisAlias: string?,
}

type Send = (player: Player, message: { [string]: any }) -> ()

local trackers: { [Player]: Tracker } = {}
-- Aktif oynama: son geçerli komutun zamanı ve dolmakta olan dakikanın saniyesi.
local activity: { [Player]: { last: number, seconds: number } } = {}
local dirty: { [Player]: boolean } = {}
local sendTimer = 0
local sendRef: Send? = nil

local function tracker(player: Player): Tracker
	local t = trackers[player]
	if t == nil then
		t = {
			alive = false,
			lives = 0,
			peak = 0,
			lifeTowers = {},
			known = {},
			kings = 0,
			peakTowers = 0,
			lifeKings = 0,
			bestAtStart = 0,
			recordFired = false,
			startedAt = 0,
			combo = 0,
			comboAt = 0,
			nemesisId = nil,
			nemesisAlias = nil,
		}
		trackers[player] = t
	end
	return t
end

local function copySet(set: { [number]: boolean }): { [number]: boolean }
	local out = {}
	for k in set do
		out[k] = true
	end
	return out
end

-- Profil hazırsa günü güncelle, `fn` olayları döndürsün; olayları istemciye bildir.
local function apply(player: Player, fn: (any) -> { Rewards.Event })
	local events: { Rewards.Event } = {}
	Profiles.mutate(player, function(profile)
		Rewards.ensureDay(profile, player.UserId, Rewards.dayOf(os.time()))
		events = fn(profile)
	end)
	-- Ekonomi analitiği: olay başına bir kaynak kaydı; bakiye, sondaki bakiyeden geriye sayılır.
	local profile = Profiles.get(player)
	if profile then
		local gains: { { sku: string, amount: number } } = {}
		local total = 0
		for _, event in events do
			local e = event :: any
			if type(e.reward) == "number" and e.reward > 0 then
				table.insert(gains, { sku = e.kind, amount = e.reward })
				total += e.reward
			end
			if type(e.chest) == "number" and e.chest > 0 then
				table.insert(gains, { sku = "chest", amount = e.chest })
				total += e.chest
			end
		end
		local balance = profile.credits - total
		for _, gain in gains do
			balance += gain.amount
			Analytics.economy(
				player,
				true,
				gain.amount,
				balance,
				Enum.AnalyticsEconomyTransactionType.Gameplay,
				gain.sku
			)
		end
	end
	local send = sendRef
	if send then
		for _, event in events do
			-- Hayat ödülü ölüm ekranında gösterilir (0 da olsa); hedef ve kilit açma bildirim.
			send(player, { kind = "Reward", event = event })
		end
	end
end

local function finishLife(player: Player, t: Tracker)
	if not t.alive then
		return
	end
	t.alive = false
	local peak = t.peak
	apply(player, function(profile)
		local events = Rewards.onLifeEnd(profile, peak)
		for _, event in events do
			if event.kind == "life" then
				event.towers = t.peakTowers
				event.kings = t.lifeKings
				event.best = t.bestAtStart
				event.cutoff = Rankings.weeklyCutoff()
				event.seconds = math.floor(os.clock() - t.startedAt)
				event.nemesis = t.nemesisAlias
			end
		end
		return events
	end)
	Rankings.submit(player, peak)
end

local function profileMessage(player: Player): { [string]: any }
	local profile = Profiles.get(player)
	local message: { [string]: any } = { kind = "Profile", state = Profiles.state(player) }
	if profile then
		message.credits = profile.credits
		message.owned = profile.owned
		message.passes = InventoryService.ownedPasses(player)
		message.equipped = profile.equipped
		message.goals = profile.daily.goals
		message.day = profile.daily.day
		message.captures = profile.stats.captures
		message.frameCaptures = Rewards.FRAME_CAPTURES
		message.audio = profile.audio
		message.lowGraphics = profile.lowGraphics
		message.oncePacks = profile.oncePacks
		message.achievements = profile.achievements
		message.stats = {
			kings = profile.stats.kings,
			captures = profile.stats.captures,
			upgrades = profile.stats.upgrades,
			bestScore = profile.stats.bestScore,
		}
		message.minutes = profile.daily.minutes
		message.streak = profile.streak.count
		message.tutorialDone = profile.tutorialDone
		message.activeMinutes = profile.stats.activeMinutes
	end
	return message
end

function AccountRewards.start(send: Send)
	sendRef = send
	Profiles.changed:Connect(function(player: Player)
		dirty[player] = true
	end)
	Profiles.onBeforeRelease(function(player: Player)
		local t = trackers[player]
		if t then
			finishLife(player, t)
		end
		trackers[player] = nil
		dirty[player] = nil
	end)
	Players.PlayerRemoving:Connect(function(player)
		trackers[player] = nil
		dirty[player] = nil
		activity[player] = nil
	end)
end

-- Yalnız Studio test komutu (DevState `profile` "toast"): ödül bildirimi gönder, profile dokunmaz.
function AccountRewards.devNotify(player: Player, event: Rewards.Event)
	local send = sendRef
	if send then
		send(player, { kind = "Reward", event = event })
	end
end

-- Oyuncu geçerli bir oyun komutu verdi (AFK ayrımı).
function AccountRewards.noteActivity(player: Player)
	local a = activity[player]
	if a then
		a.last = os.clock()
	else
		activity[player] = { last = os.clock(), seconds = 0 }
	end
end

-- Upgrade komutu başarılı oldu.
function AccountRewards.onUpgrade(player: Player)
	Analytics.step(player, "Upgraded")
	apply(player, function(profile)
		return Rewards.onUpgrade(profile)
	end)
end

-- Sim adım(lar)ından sonra çağrılır. `dt`: geçen gerçek süre (profil gönderim aralığı için).
function AccountRewards.step(sim: Game.Game, simIds: { [Player]: number }, dt: number)
	for player, simId in simIds do
		local data = sim.players[simId]
		if data ~= nil then
			local t = tracker(player)
			if data.kings > t.kings then
				local gained = data.kings - t.kings
				t.kings = data.kings
				t.lifeKings += gained
				apply(player, function(profile)
					return Rewards.onKingKill(profile, gained)
				end)
				if t.nemesisId ~= nil and data.lastVictim == t.nemesisId then
					t.nemesisId = nil
					t.nemesisAlias = nil
					apply(player, function(profile)
						return Rewards.onRevenge(profile)
					end)
				end
			end
			local a = activity[player]
			if data.alive and a and os.clock() - a.last <= Rewards.ACTIVE_WINDOW then
				a.seconds += dt
				if a.seconds >= 60 then
					a.seconds -= 60
					apply(player, function(profile)
						return Rewards.onActiveMinute(profile)
					end)
				end
			end
			if data.alive then
				if not t.alive then
					-- Yeni hayat: doğuştaki kule(ler) taban; fetih sayılmaz.
					t.alive = true
					if t.lives > 0 then
						Analytics.step(player, "PlayedAgain")
						Analytics.event(player, "PlayedAgain")
					end
					t.lives += 1
					Analytics.step(player, "Spawned")
					t.peak = 0
					t.peakTowers = 0
					t.lifeKings = 0
					local saved = Profiles.get(player)
					t.bestAtStart = if saved then saved.stats.bestScore else 0
					t.recordFired = false
					t.startedAt = os.clock()
					t.combo = 0
					t.lifeTowers = {}
					t.known = copySet(data.towers)
					local now = os.time()
					apply(player, function(profile)
						return Rewards.onDayPlayed(
							profile,
							Rewards.dayOf(now),
							Rewards.dayOf(now - 86400)
						)
					end)
				else
					for id in data.towers do
						if not t.known[id] then
							Analytics.step(player, "Captured")
							local fresh = not t.lifeTowers[id]
							apply(player, function(profile)
								return Rewards.onCapture(profile, id, t.lifeTowers)
							end)
							if fresh then
								local now = os.clock()
								t.combo = if now - t.comboAt <= Rewards.COMBO_WINDOW
									then t.combo + 1
									else 1
								t.comboAt = now
								local combo = t.combo
								apply(player, function(profile)
									return Rewards.onCombo(profile, combo)
								end)
							end
						end
					end
					t.known = copySet(data.towers)
				end
				local towers = 0
				for _ in data.towers do
					towers += 1
				end
				t.peakTowers = math.max(t.peakTowers, towers)
				if data.score > t.peak then
					t.peak = data.score
					local score = data.score
					apply(player, function(profile)
						return Rewards.onScore(profile, score)
					end)
					if t.bestAtStart > 0 and score > t.bestAtStart and not t.recordFired then
						t.recordFired = true
						apply(player, function(_profile)
							return { { kind = "record", score = score } }
						end)
					end
				end
			else
				if t.alive then
					Analytics.step(player, "Died")
					Analytics.event(player, "Died")
					local killer = data.killedBy
					local killerData = if killer ~= nil then sim.players[killer] else nil
					if killerData ~= nil and killer ~= simId then
						t.nemesisId = killer
						t.nemesisAlias = killerData.alias
					end
				end
				finishLife(player, t)
			end
		end
	end
	sendTimer += dt
	local send = sendRef
	if sendTimer >= PROFILE_SEND_PERIOD and send then
		sendTimer = 0
		for player in dirty do
			send(player, profileMessage(player))
		end
		table.clear(dirty)
	end
end

return AccountRewards
