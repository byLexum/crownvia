--!strict
-- Kalıcı sıralama (kodiak `LeaderboardOverlay`: günlük, haftalık, tüm zamanlar). Skor: hayatın en
-- yüksek skoru. `OrderedDataStore` dönem başına ayrı; sonuç önbellekte tutulur, istek bütçesi
-- oyuncu sayısına değil REFRESH_SECS'e bağlıdır. Geçen haftanın ilk WEEKLY_TOP oyuncusu kozmetik
-- rozet alır (proje kararı 2026-11-06). Depo yoksa boş liste; oyun etkilenmez.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rewards = require(Shared:WaitForChild("Account"):WaitForChild("Rewards"))

local Profiles = require(script.Parent.Profiles)

export type Send = (player: Player, message: { [string]: any }) -> ()
export type Entry = { name: string, score: number, you: boolean? }

local Rankings = {}

local REFRESH_SECS = 120
local LIST_SIZE = 20
local WEEKLY_TOP = 10
local DAY_SECS = 86400
local WEEK_SECS = 7 * DAY_SECS
local PERIODS = { "daily", "weekly", "allTime" }

type Cached = { at: number, ids: { number }, scores: { number } }

local cache: { [string]: Cached } = {}
local names: { [number]: string } = {}
local lastWeekTop: { week: number, ids: { [number]: boolean } }? = nil

local function weekIndex(now: number): number
	return now // WEEK_SECS
end

local function storeName(period: string, now: number): string
	if period == "daily" then
		return "CrownviaDay_" .. Rewards.dayOf(now)
	elseif period == "weekly" then
		return "CrownviaWeek_" .. weekIndex(now)
	end
	return "CrownviaAllTime"
end

local function store(name: string): OrderedDataStore?
	local ok, value = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	return if ok then value else nil
end

local function readTop(name: string, size: number): ({ number }, { number })
	local ids, scores = {}, {}
	local ordered = store(name)
	if ordered == nil then
		return ids, scores
	end
	local ok, pages = pcall(function()
		return ordered:GetSortedAsync(false, size)
	end)
	if ok then
		for _, entry in pages:GetCurrentPage() do
			local id = tonumber(entry.key)
			if id ~= nil then
				table.insert(ids, id)
				table.insert(scores, entry.value)
			end
		end
	end
	return ids, scores
end

local function loadNames(ids: { number })
	local missing = {}
	for _, id in ids do
		if names[id] == nil then
			table.insert(missing, id)
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(function()
		return UserService:GetUserInfosByUserIdsAsync(missing)
	end)
	if ok then
		for _, info in infos do
			names[info.Id] = info.DisplayName
		end
	end
end

local function period(name: string): Cached
	local now = os.time()
	local current = cache[name]
	if current ~= nil and now - current.at < REFRESH_SECS then
		return current
	end
	local ids, scores = readTop(storeName(name, now), LIST_SIZE)
	loadNames(ids)
	local fresh = { at = now, ids = ids, scores = scores }
	cache[name] = fresh
	return fresh
end

-- Hayat bitti: dönem depolarında en iyi skoru güncelle.
function Rankings.submit(player: Player, score: number)
	if score <= 0 then
		return
	end
	local key = tostring(player.UserId)
	local now = os.time()
	task.spawn(function()
		for _, name in PERIODS do
			local ordered = store(storeName(name, now))
			if ordered ~= nil then
				local ok, err = pcall(function()
					(ordered :: any):UpdateAsync(key, function(old: number?): number?
						return if old == nil or score > old then score else nil
					end)
				end)
				if not ok then
					warn("[robgame] rankings submit failed: " .. tostring(err))
				end
			end
		end
		period("weekly")
	end)
end

-- Haftanın ilk 10'una giriş skoru (önbellekten, bekletmez). Liste dolu değilse nil.
function Rankings.weeklyCutoff(): number?
	local data = cache.weekly
	return if data then data.scores[WEEKLY_TOP] else nil
end

-- Oyuncunun kendi dönem skoru (ilk 20'de değilse sıralama ekranı bunu ayrı satırda gösterir).
-- Depo okuması pahalı: oyuncu başına MINE_REFRESH_SECS önbellek.
local MINE_REFRESH_SECS = 60
local mineCache: { [number]: { at: number, scores: { [string]: number } } } = {}

local function ownScores(player: Player): { [string]: number }
	local now = os.time()
	local cached = mineCache[player.UserId]
	if cached ~= nil and now - cached.at < MINE_REFRESH_SECS then
		return cached.scores
	end
	local scores: { [string]: number } = {}
	for _, name in PERIODS do
		local ordered = store(storeName(name, now))
		if ordered ~= nil then
			local ok, value = pcall(function(): any
				local score: any = (ordered :: any):GetAsync(tostring(player.UserId))
				return score
			end)
			if ok and type(value) == "number" then
				scores[name] = value
			end
		end
	end
	mineCache[player.UserId] = { at = now, scores = scores }
	return scores
end

Players.PlayerRemoving:Connect(function(player: Player)
	mineCache[player.UserId] = nil
end)

-- İstemci sıralama ekranını açtı. `resets`: günlük ve haftalık listenin sıfırlanmasına kalan saniye
-- (UTC gün ve hafta sınırı, depo adlarıyla aynı); `mine`: kendi skoru, listede yoksa gösterilir.
function Rankings.send(player: Player, send: Send)
	local now = os.time()
	local message: { [string]: any } = {
		kind = "Rankings",
		resets = { daily = DAY_SECS - now % DAY_SECS, weekly = WEEK_SECS - now % WEEK_SECS },
	}
	local inList: { [string]: boolean } = {}
	for _, name in PERIODS do
		local data = period(name)
		local list: { Entry } = {}
		for i, id in data.ids do
			table.insert(list, {
				name = names[id] or "Commander",
				score = data.scores[i],
				you = if id == player.UserId then true else nil,
			})
			if id == player.UserId then
				inList[name] = true
			end
		end
		message[name] = list
	end
	local mine: { [string]: number } = {}
	local missing = false
	for _, name in PERIODS do
		if not inList[name] then
			missing = true
		end
	end
	if missing then
		for name, score in ownScores(player) do
			if not inList[name] then
				mine[name] = score
			end
		end
	end
	message.mine = mine
	send(player, message)
end

-- Girişte: geçen haftanın ilk oyuncularındansa rozeti ver (bir kez).
function Rankings.claimWeekly(player: Player)
	local week = weekIndex(os.time()) - 1
	local top = lastWeekTop
	if top == nil or top.week ~= week then
		local ids = readTop("CrownviaWeek_" .. week, WEEKLY_TOP)
		local set = {}
		for _, id in ids do
			set[id] = true
		end
		top = { week = week, ids = set }
		lastWeekTop = top
	end
	if not (top :: any).ids[player.UserId] then
		return
	end
	Profiles.mutate(player, function(profile)
		profile.owned[Rewards.CHAMPION_ITEM] = true
	end)
end

function Rankings.start(
	send: Send
): { [string]: (player: Player, payload: { [string]: any }) -> string? }
	local function onReady(player: Player)
		task.spawn(function()
			-- Profil yüklenene kadar bekle (en çok 60 sn).
			for _ = 1, 60 do
				if player.Parent == nil then
					return
				end
				if Profiles.get(player) ~= nil then
					Rankings.claimWeekly(player)
					return
				end
				task.wait(1)
			end
		end)
	end
	Players.PlayerAdded:Connect(onReady)
	for _, player in Players:GetPlayers() do
		onReady(player)
	end
	return {
		RankingsGet = function(player: Player, _payload: { [string]: any }): string?
			task.spawn(Rankings.send, player, send)
			return nil
		end,
	}
end

return Rankings
