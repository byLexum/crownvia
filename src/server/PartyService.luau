--!strict
-- Parti sunucusu (kodiak "Play with friends") Roblox bağlantısı. Mantık saf modülde:
-- `Shared/Party/PartyCore.luau` (Lune testli). Burası yalnız Roblox servislerini bağlar:
--   - Kayıt deposu: `MemoryStoreService:GetHashMap` (sunucular arası, süreli).
--   - Işınlama: `TeleportService:TeleportAsync` + `TeleportOptions.ReservedServerId` (güncel yol;
--     `ReserveServer` ve `TeleportToPrivateServer` belgede "Deprecated").
--   - Davet: istemci `SocialService:PromptGameInvite` + `ExperienceInviteOptions.LaunchData`;
--     davetli `Player:GetJoinData().LaunchData` ile gelir, burada doğrulanır.
-- Genel sunucunun otomatik bot sayısı değişmez; yalnız parti sunucusunda sabit sayı kullanılır.
-- Studio'da ışınlama çalışmaz (Roblox belgesi); MemoryStore yayınlanmış yer + API erişimi ister.
-- Ayrıntılar: docs/API.md "Parti".

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PartyCore = require(Shared:WaitForChild("Party"):WaitForChild("PartyCore"))
local PartyRules = require(Shared:WaitForChild("Party"):WaitForChild("PartyRules"))
local BotRepo = require(Shared:WaitForChild("Sim"):WaitForChild("BotRepo"))
local WorldService = require(script.Parent.WorldService)

type Core = PartyCore.Core<Player>

export type Send = (player: Player, message: { [string]: any }) -> ()

local PartyService = {}

local MAP_NAME = "CrownviaParty"
-- Davet verisi birkaç saniye geç gelebilir (Roblox belgesi: 10 deneme, 1 sn arayla).
local LAUNCH_DATA_TRIES = 10
-- Oda kaydı, kurucunun ışınlaması bitince yazılan dizinle bulunur; birkaç kez denenir.
local ROOM_LOAD_TRIES = 5
local ROOM_LOAD_RETRY_SECS = 2

local core: Core? = nil
local send: Send = function(_player: Player, _message: { [string]: any }) end
local bots: BotRepo.BotRepo? = nil
local kind: PartyRules.ServerKind = "public"
-- Oyuncunun son parti işlemi (TeleportInitFailed hangi işleme ait).
local lastAction: { [Player]: string } = {}
local roomLoading = false

local function store(): PartyCore.Store
	local map: MemoryStoreHashMap? = nil
	local function getMap(): MemoryStoreHashMap
		if map == nil then
			map = MemoryStoreService:GetHashMap(MAP_NAME)
		end
		return map :: MemoryStoreHashMap
	end
	return {
		get = function(key)
			local ok, value = pcall(function()
				return getMap():GetAsync(key)
			end)
			if not ok then
				warn("[robgame] party store get failed: " .. tostring(value))
			end
			return ok, if ok then value else nil
		end,
		set = function(key, value, ttl)
			local ok, err = pcall(function()
				return getMap():SetAsync(key, value, ttl)
			end)
			if not ok then
				warn("[robgame] party store set failed: " .. tostring(err))
			end
			return ok and err == true
		end,
		update = function(key, fn, ttl)
			local ok, value = pcall(function()
				return getMap():UpdateAsync(key, fn, ttl)
			end)
			if not ok then
				warn("[robgame] party store update failed: " .. tostring(value))
			end
			return ok, if ok then value else nil
		end,
	}
end

local function teleport(
	players: { Player },
	reservedServerId: string?,
	data: { [string]: any }?
): PartyCore.TeleportOutcome
	local options = Instance.new("TeleportOptions")
	if reservedServerId ~= nil then
		options.ReservedServerId = reservedServerId
	end
	if data ~= nil then
		-- Güvenli değil (istemci görür): yalnız ipucu. Asıl doğrulama depodaki kayıtla.
		options:SetTeleportData(data)
	end
	local ok, result = pcall(function()
		return TeleportService:TeleportAsync(game.PlaceId, players, options)
	end)
	if not ok then
		warn("[robgame] teleport failed: " .. tostring(result))
		return { ok = false, flooded = string.find(tostring(result), "Flood", 1, true) ~= nil }
	end
	local privateServerId: string? = nil
	if typeof(result) == "Instance" and result:IsA("TeleportAsyncResult") then
		privateServerId = result.PrivateServerId
	end
	return { ok = true, privateServerId = privateServerId }
end

local function newCore(): Core
	return PartyCore.new({
		store = store(),
		now = os.time,
		clock = os.clock,
		newId = function()
			return string.lower(HttpService:GenerateGUID(false))
		end,
		userId = function(player: Player)
			return player.UserId
		end,
		teleport = teleport,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
	})
end

local function status(player: Player, action: string, stage: string, reason: string?)
	send(player, { kind = "PartyStatus", action = action, stage = stage, reason = reason })
end

local function broadcastInfo()
	local room = (core :: Core).room
	for _, player in Players:GetPlayers() do
		send(player, {
			kind = "PartyInfo",
			partyId = if room then room.partyId else nil,
			bots = if room then room.bots else nil,
			founder = room ~= nil and room.founder == player.UserId,
		})
	end
end

local function applyBots(count: number, aggression: number?)
	local repo = bots
	if repo then
		repo.fixedCount = count
		if aggression ~= nil then
			repo.aggression = aggression
		end
	end
end

-- Işınlama sürdüğünü bildir, sonra sonucu. `run` hata kodu ya da nil döner.
local function runAction(player: Player, action: string, run: () -> string?)
	lastAction[player] = action
	status(player, action, "working", nil)
	local reason = run()
	if reason ~= nil then
		status(player, action, "failed", reason)
	else
		status(player, action, "teleporting", nil)
	end
end

-- Parti sunucusu açılışı: odayı kayıttan yükle. İlk oyuncunun ışınlama verisi yalnız ipucu.
local function loadRoom(player: Player)
	local c = core :: Core
	if c.room ~= nil or roomLoading then
		return
	end
	roomLoading = true
	local joinData = player:GetJoinData()
	local teleportData = joinData.TeleportData
	local hint = if type(teleportData) == "table" then (teleportData :: any).party else nil
	for attempt = 1, ROOM_LOAD_TRIES do
		if PartyCore.loadRoom(c, game.PrivateServerId, hint) ~= nil then
			break
		end
		if attempt < ROOM_LOAD_TRIES then
			task.wait(ROOM_LOAD_RETRY_SECS)
		end
	end
	roomLoading = false
	local room = c.room
	if room == nil then
		-- Kayıt bulunamadı (depo yok ya da süresi doldu): oyun sürer, kimse ayar değiştiremez.
		warn("[robgame] party room record not found; using default bots")
		applyBots(PartyRules.DEFAULT_BOTS)
		broadcastInfo()
		return
	end
	print(
		string.format(
			"[robgame] party room %s: %d bots, aggression %s",
			room.partyId,
			room.bots,
			tostring(room.aggression)
		)
	)
	applyBots(room.bots, room.aggression)
	broadcastInfo()
end

-- Genel sunucu: davetle gelen oyuncunun davet verisini oku, doğrula, partisine götür.
local function readInvite(player: Player)
	local c = core :: Core
	for attempt = 1, LAUNCH_DATA_TRIES do
		if player.Parent == nil then
			return
		end
		local launchData = player:GetJoinData().LaunchData
		if type(launchData) == "string" and launchData ~= "" then
			if PartyCore.setPendingJoin(c, player, launchData) then
				runAction(player, "Join", function()
					return PartyCore.join(c, player)
				end)
			end
			return
		end
		if attempt < LAUNCH_DATA_TRIES then
			task.wait(1)
		end
	end
end

local function onPlayerAdded(player: Player)
	if kind == "reserved" then
		local c = core :: Core
		if c.room == nil then
			task.spawn(loadRoom, player)
		else
			-- Oda boşalıp kapanmışken biri geldiyse (ışınlama sürüyordu) yeniden aç.
			task.spawn(function()
				PartyCore.reopen(c, game.PrivateServerId)
			end)
			broadcastInfo()
		end
	elseif kind == "public" then
		task.spawn(readInvite, player)
	end
end

-- Komut işleyicileri (`CommandRemote`). Sonuç `PartyStatus` ile gider; burada hata dönülmez.
local function handlers(): { [string]: (player: Player, payload: { [string]: any }) -> string? }
	return {
		PartyCreate = function(player, payload)
			local invite = payload.invite == true
			local difficulty = payload.difficulty
			runAction(player, if difficulty ~= nil then "Solo" else "Create", function()
				return PartyCore.create(core :: Core, player, payload.bots, invite, difficulty)
			end)
			return nil
		end,
		WorldJoin = function(player, payload)
			runAction(player, "World", function()
				return WorldService.join(player, payload.id)
			end)
			return nil
		end,
		PartyJoin = function(player, _payload)
			runAction(player, "Join", function()
				return PartyCore.join(core :: Core, player)
			end)
			return nil
		end,
		PartyLeave = function(player, _payload)
			runAction(player, "Leave", function()
				return PartyCore.leave(core :: Core, player)
			end)
			return nil
		end,
		PartySetBots = function(player, payload)
			local err, count = PartyCore.setBots(core :: Core, player, payload.bots)
			if err ~= nil then
				status(player, "SetBots", "failed", err)
			else
				applyBots(count :: number)
				broadcastInfo()
			end
			return nil
		end,
	}
end

function PartyService.start(
	botRepo: BotRepo.BotRepo,
	sendMessage: Send
): { [string]: (player: Player, payload: { [string]: any }) -> string? }
	core = newCore()
	send = sendMessage
	bots = botRepo
	kind = PartyRules.serverKind(game.PrivateServerId, game.PrivateServerOwnerId)
	WorldService.start(kind == "public", sendMessage)
	if kind == "reserved" then
		-- Oda kaydı gelene kadar bot yok (otomatik 10 bot doğup sonra silinmesin).
		applyBots(0)
	end

	TeleportService.TeleportInitFailed:Connect(function(player, result, message)
		local action = lastAction[player]
		if action == nil then
			return
		end
		warn(string.format("[robgame] teleport init failed: %s %s", result.Name, message))
		status(player, action, "failed", PartyCore.teleportFailedReason(result.Name))
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		PartyCore.forget(core :: Core, player)
		lastAction[player] = nil
		-- Kurucu ayrılsa da oda sürer; son oyuncu çıkınca davet kapanır.
		if kind == "reserved" and #Players:GetPlayers() <= 1 then
			PartyCore.close(core :: Core)
		end
	end)

	if kind == "reserved" then
		game:BindToClose(function()
			PartyCore.close(core :: Core)
		end)
		task.spawn(function()
			while true do
				task.wait(PartyCore.HEARTBEAT_SECS)
				if #Players:GetPlayers() > 0 then
					PartyCore.heartbeat(core :: Core)
				end
			end
		end)
	end

	return handlers()
end

-- Yalnız Studio testi (DevState): ışınlama olmadan parti odasını taklit et.
function PartyService.devSimulateRoom(count: any, founder: number): string
	local c = core :: Core
	local entry = if type(count) == "string" then PartyRules.DIFFICULTIES[count] else nil
	local valid = if entry then entry.bots else PartyRules.validateBots(count)
	if valid == nil then
		return "invalid bots"
	end
	local aggression = if entry then entry.aggression else PartyRules.DEFAULT_AGGRESSION
	c.room = {
		partyId = "00000000-0000-4000-8000-000000000000",
		founder = founder,
		bots = valid,
		aggression = aggression,
	}
	kind = "reserved"
	applyBots(valid, aggression)
	broadcastInfo()
	return string.format(
		"simulated party room with %d bots, aggression %s",
		valid,
		tostring(aggression)
	)
end

function PartyService.serverKind(): PartyRules.ServerKind
	return kind
end

return PartyService
