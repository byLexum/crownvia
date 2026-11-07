--!strict
-- Genel sunucu listesi: her genel sunucu durumunu `MemoryStoreSortedMap`e yazar, listeyi okuyup
-- istemcilere yollar, oyuncuyu seçtiği sunucuya `TeleportOptions.ServerInstanceId` ile ışınlar.
-- Mantık `Shared/Party/WorldList`. Depo yoksa (Studio) liste yalnız bulunulan sunucudur.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local PartyFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Party")
local PartyRules = require(PartyFolder:WaitForChild("PartyRules"))
local WorldList = require(PartyFolder:WaitForChild("WorldList"))

export type Send = (player: Player, message: { [string]: any }) -> ()

local WorldService = {}

local MAP_NAME = "CrownviaWorlds"
local READ_LIMIT = 50

local leader: string? = nil
local isPublic = false
local rows: { WorldList.Row } = {}
local signature = ""
-- Son listede görülen sunucular: istemciden gelen kimlik yalnız bunlardan biri olabilir.
local known: { [string]: boolean } = {}
local lastOthers: { WorldList.Entry } = {}
local worldSend: Send = function(_player: Player, _message: { [string]: any }) end

local function hereEntry(): WorldList.Entry?
	if not isPublic then
		return nil
	end
	return {
		id = if game.JobId ~= "" then game.JobId else WorldList.HERE,
		players = #Players:GetPlayers(),
		max = Players.MaxPlayers,
		leader = leader,
		at = os.time(),
	}
end

local function publish(map: MemoryStoreSortedMap)
	local entry = hereEntry()
	if entry == nil or game.JobId == "" then
		return
	end
	local ok, err = pcall(function()
		map:SetAsync(game.JobId, entry, WorldList.RECORD_TTL)
	end)
	if not ok then
		warn("[robgame] world publish failed: " .. tostring(err))
	end
end

local function readOthers(map: MemoryStoreSortedMap): { WorldList.Entry }
	local ok, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Descending, READ_LIMIT)
	end)
	local others: { WorldList.Entry } = {}
	if not ok then
		return others
	end
	local now = os.time()
	for _, item in items :: { any } do
		local entry = WorldList.validate(item.key, item.value, now)
		if entry ~= nil then
			table.insert(others, entry)
		end
	end
	return others
end

local function rowSignature(list: { WorldList.Row }): string
	local parts = {}
	for _, row in list do
		table.insert(
			parts,
			string.format("%s:%d:%d:%s", row.id, row.players, row.max, row.leader or "")
		)
	end
	return table.concat(parts, ",")
end

-- Satırları son okunan listeden yeniden kur; değiştiyse herkese yolla.
local function rebuild(send: Send)
	rows = WorldList.rows(hereEntry(), lastOthers)
	table.clear(known)
	for _, row in rows do
		if not row.here then
			known[row.id] = true
		end
	end
	local nextSignature = rowSignature(rows)
	if nextSignature ~= signature then
		signature = nextSignature
		for _, player in Players:GetPlayers() do
			send(player, { kind = "Worlds", rows = rows })
		end
	end
end

function WorldService.setLeader(alias: string?)
	leader = alias
end

-- Seçilen sunucuya ışınla. nil → ışınlama başladı, aksi hâlde hata kodu.
function WorldService.join(player: Player, id: unknown): string?
	if type(id) ~= "string" or not known[id] then
		return PartyRules.Reason.WORLD_GONE
	end
	local options = Instance.new("TeleportOptions")
	options.ServerInstanceId = id
	options:SetTeleportData({ autoPlay = true })
	local ok, err = pcall(function()
		return TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not ok then
		warn("[robgame] world teleport failed: " .. tostring(err))
		return PartyRules.Reason.TELEPORT_FAILED
	end
	return nil
end

-- Yalnız Studio testi (DevState): depo olmadan başka sunucular varmış gibi göster.
function WorldService.devFake(count: number): string
	table.clear(lastOthers)
	for i = 1, count do
		table.insert(lastOthers, {
			id = "dev-" .. i,
			players = 30 - i * 7,
			max = 30,
			leader = "Commander " .. i,
			at = os.time(),
		})
	end
	rebuild(worldSend)
	return "fake worlds: " .. count
end

function WorldService.start(public: boolean, send: Send)
	isPublic = public
	worldSend = send
	local mapOk, map = pcall(function()
		return MemoryStoreService:GetSortedMap(MAP_NAME)
	end)
	local store: MemoryStoreSortedMap? = if mapOk then map else nil

	local function greet(player: Player)
		rebuild(send)
		send(player, { kind = "Worlds", rows = rows })
	end
	Players.PlayerAdded:Connect(greet)
	for _, player in Players:GetPlayers() do
		greet(player)
	end

	task.spawn(function()
		local sincePublish = WorldList.PUBLISH_SECS
		while true do
			if store ~= nil then
				if sincePublish >= WorldList.PUBLISH_SECS then
					sincePublish = 0
					publish(store)
				end
				lastOthers = readOthers(store)
			end
			rebuild(send)
			task.wait(WorldList.REFRESH_SECS)
			sincePublish += WorldList.REFRESH_SECS
		end
	end)

	if public and store ~= nil and game.JobId ~= "" then
		game:BindToClose(function()
			pcall(function()
				(store :: MemoryStoreSortedMap):RemoveAsync(game.JobId)
			end)
		end)
	end
end

return WorldService
