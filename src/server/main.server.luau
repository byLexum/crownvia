--!strict
-- Sunucu giriş noktası: Sim/Game'i 4 Hz sabit adımla çalıştırır, oyuncuları bağlar.
-- Kiomet'te karşılığı kodiak `ArenaService` döngüsü + `server/src/main.rs`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local BotRepo = require(Sim.BotRepo)
local Game = require(Sim.Game)
local Ticks = require(Sim.Ticks)

local CommandRemote = require(script.Parent.CommandRemote)
local PartyService = require(script.Parent.PartyService)
local WorldService = require(script.Parent.WorldService)
local Replication = require(script.Parent.Replication)

-- Kule modelleri istemciye kalıp olarak gider (ReplicatedStorage.TowerMeshes).
require(script.Parent.TowerMeshes).start()
-- Kalıcı profil (hesap ilerlemesi; savaş kurallarından bağımsız, `docs/HESAP_MAGAZA.md`).
require(script.Parent.Profiles).start()

-- Zemin Terrain'i (istemci Fog.luau doldurur): malzeme renkleri sunucuda ayarlanır (istemcide
-- değiştirilemedi, 2026-11-05). Çim süsü (Decoration) yalnız editörde: default.project.json.
-- Beyaz renk: Magnific dokuları (MaterialService varyantları) kendi rengiyle görünsün.
do
	local terrain = workspace.Terrain
	for _, material in
		{
			Enum.Material.Grass,
			Enum.Material.LeafyGrass,
			Enum.Material.Sandstone,
			Enum.Material.Slate,
		}
	do
		terrain:SetMaterialColor(material, Color3.new(1, 1, 1))
	end
end

-- Avatar yok: oyun yukarıdan bakılan bir haritada oynanır.
Players.CharacterAutoLoads = false

-- Oyunun kendi ışığı (yer dosyasının varsayılanına bağlı kalmasın): yumuşak öğleden sonra ışığı.
do
	local Lighting = game:GetService("Lighting")
	Lighting.Brightness = 2
	Lighting.ClockTime = 14.5
	Lighting.GeographicLatitude = 30
	Lighting.ExposureCompensation = -0.25
	Lighting.Ambient = Color3.fromRGB(70, 78, 92)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 128, 140)
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.3
end

local random = Random.new()
local sim = Game.new(function()
	return random:NextNumber()
end)

local simIds: { [Player]: number } = {}

-- Botlar (kodiak `BotRepo`): oyuncularla aynı komutları kullanır.
local bots = BotRepo.new(function()
	return random:NextNumber()
end)

-- Adım süresi ölçümü (bot üst sınırı ölçümle belirlenecek, CLAUDE.md).
local stepStats = { steps = 0, totalMs = 0, maxMs = 0, replMs = 0, replMaxMs = 0, replSteps = 0 }

-- Bağlantı tablosu ilk kullanımda kuruluyordu (ilk adım ~600 ms); oyuncular gelmeden kur.
require(Sim.TowerId).prepareConnectivity()

-- Yalnız Studio: MCP ile test komutları (ServerStorage.RobgameDev). Canlıda kurulmaz.
require(script.Parent.DevState).install(sim, simIds, bots, stepStats)

local remotes = CommandRemote.remotesFolder()
local replication = Replication.new(remotes)

-- Parti sunucusu: genel sunucuda davet/kuruluş, parti sunucusunda sabit bot sayısı.
local partyHandlers = PartyService.start(bots, function(player, message)
	replication:send(player, message)
end)

-- Karşılama hunisi (yalnız yayınlı oyunda veri toplar).
require(script.Parent.Analytics).start()

-- Hesap ödülleri (Credits, günlük hedefler): sim durumunu yalnız okur.
local AccountRewards = require(script.Parent.AccountRewards)
AccountRewards.start(function(player, message)
	replication:send(player, message)
end)

-- Envanter (Credits ile satın alma, kuşanma) ve kozmetik yayını.
local InventoryService = require(script.Parent.InventoryService)
local inventoryHandlers = InventoryService.start(function(player, message)
	replication:send(player, message)
end)

-- Kalıcı sıralama (günlük, haftalık, tüm zamanlar).
local rankingsHandlers = require(script.Parent.Rankings).start(function(player, message)
	replication:send(player, message)
end)

-- Robux: Credits paketleri (ProcessReceipt) ve kozmetik Game Pass'ler.
require(script.Parent.PurchaseService).start(function(player, message)
	replication:send(player, message)
end)

local Path = require(Sim.Path)

-- `World::MAX_PATH_ROADS`
local MAX_PATH_LENGTH = Path.MAX_PATH_ROADS

-- İstemciden gelen sayı geçerli bir TowerId mi (tamsayı, u16 çifti).
local function isTowerId(value: unknown): boolean
	return type(value) == "number"
		and value >= 0
		and value < 4294967296
		and value == math.floor(value)
end

-- İstemciden gelen yol listesini doğrular: tablo, en fazla MAX_PATH_LENGTH geçerli TowerId.
local function readPath(path: unknown): ({ number }?, string?)
	if type(path) ~= "table" then
		return nil, "malformed command"
	end
	local list = path :: { [number]: unknown }
	local ids = {}
	for i = 1, MAX_PATH_LENGTH + 1 do
		local id = list[i]
		if id == nil then
			break
		end
		if not isTowerId(id) then
			return nil, "malformed path"
		end
		table.insert(ids, id :: number)
	end
	if #ids > MAX_PATH_LENGTH then
		return nil, "path too long"
	end
	return ids, nil
end

local handlers: { [string]: CommandRemote.Handler } = {
	-- `Command::Spawn(alias)`. Takma ad Roblox görünen adıdır (Roblox tarafından denetlenir).
	Spawn = function(player: Player, _payload)
		local simId = simIds[player]
		if simId == nil then
			return "unknown player"
		end
		local err = Game.spawnPlayer(sim, simId, player.DisplayName)
		if err == nil then
			replication:hello(player, simId, sim.world.tick)
		end
		return err
	end,

	-- `Command::DeployForce { tower_id, path }`. Şekil burada, kurallar Game.deployForce'ta doğrulanır.
	DeployForce = function(player: Player, payload)
		local simId = simIds[player]
		if simId == nil then
			return "unknown player"
		end
		if not isTowerId(payload.towerId) then
			return "malformed command"
		end
		local ids, err = readPath(payload.path)
		if ids == nil then
			return err
		end
		return Game.deployForce(sim, simId, payload.towerId, ids)
	end,

	-- `Command::SetSupplyLine { tower_id, path: Option<Path> }`. `path` nil → hattı kaldır.
	SetSupplyLine = function(player: Player, payload)
		local simId = simIds[player]
		if simId == nil then
			return "unknown player"
		end
		if not isTowerId(payload.towerId) then
			return "malformed command"
		end
		local ids: { number }? = nil
		if payload.path ~= nil then
			local parsed, err = readPath(payload.path)
			if parsed == nil then
				return err
			end
			ids = parsed
		end
		return Game.setSupplyLine(sim, simId, payload.towerId, ids)
	end,

	-- `Command::Upgrade { tower_id, tower_type }`. Tip aralığı Game.upgradeTower'da doğrulanır.
	Upgrade = function(player: Player, payload)
		local simId = simIds[player]
		if simId == nil then
			return "unknown player"
		end
		if not isTowerId(payload.towerId) or type(payload.towerType) ~= "number" then
			return "malformed command"
		end
		local err = Game.upgradeTower(sim, simId, payload.towerId, payload.towerType)
		if err == nil then
			AccountRewards.onUpgrade(player)
		end
		return err
	end,

	-- `Command::Alliance { with, break_alliance }`
	Alliance = function(player: Player, payload)
		local simId = simIds[player]
		if simId == nil then
			return "unknown player"
		end
		local with = payload.with
		if
			type(with) ~= "number"
			or with ~= math.floor(with)
			or type(payload.breakAlliance) ~= "boolean"
		then
			return "malformed command"
		end
		return Game.alliance(sim, simId, with, payload.breakAlliance)
	end,
}
-- Aktif oynama ödülü: yalnız kabul edilen oyun komutları sayılır (AFK ödüllendirilmez).
for _, kind in { "DeployForce", "SetSupplyLine", "Upgrade", "Alliance" } do
	local handler = handlers[kind]
	handlers[kind] = function(player: Player, payload): string?
		local err = handler(player, payload)
		if err == nil then
			AccountRewards.noteActivity(player)
		end
		return err
	end
end
for kind, handler in inventoryHandlers do
	handlers[kind] = handler
end
for kind, handler in rankingsHandlers do
	handlers[kind] = handler
end
for kind, handler in partyHandlers do
	handlers[kind] = handler
end

CommandRemote.start(handlers, function(player: Player, kind: string, reason: string)
	-- Yalnız Spawn'ın sonucu istemcide bekleniyor (ölüm ekranı açık kalır). Ham hata metni yerine
	-- kısa kod gönderilir. Diğer komutların hataları şimdilik yalnız sunucu çıktısında.
	if kind == "Spawn" then
		replication:spawnFailed(
			player,
			if reason == "rate limited" then "RATE_LIMITED" else "SPAWN_FAILED"
		)
	end
end)

local function onPlayerAdded(player: Player)
	if simIds[player] ~= nil then
		return
	end
	simIds[player] = Game.playerJoined(sim, false)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

-- Bilinçli sapma: kaynakta 30 sn LIMBO var; bizde oyuncu ayrıldığı an öldürülür.
Players.PlayerRemoving:Connect(function(player)
	local simId = simIds[player]
	simIds[player] = nil
	InventoryService.markDirty()
	replication:remove(player)
	if simId ~= nil then
		Game.playerQuit(sim, simId)
	end
end)

-- Sabit adım: 250 ms. Kare başına en fazla 4 adım (gecikmede sarmal büyümesin).
local STEP = Ticks.PERIOD_SECS
local MAX_STEPS_PER_FRAME = 4
local accumulator = 0

-- Canlı skor tablosu (kodiak `LiveboardRepo`): saniyede bir hesaplanır, değişince gönderilir.
-- Botlar canlıda da tabloda (kaynakta yalnız geliştirme sürümünde; proje kararı 2026-11-06).
local Liveboard = require(Sim.Liveboard)
local LIVEBOARD_PERIOD = 1
local liveboardTimer = 0
local sentLiveboard: { [Player]: string } = {}

-- Menü arkası canlı dünyada izlenen bot.
local spectateTarget: number? = nil

local function sendLiveboard()
	spectateTarget = BotRepo.spectateTarget(bots, sim, spectateTarget)
	replication:spectate(simIds, spectateTarget, sim.world.tick)
	local views: { [number]: Liveboard.PlayerView } = {}
	for id, data in sim.players do
		views[id] =
			{ alive = data.alive, score = data.score, alias = data.alias, isBot = data.isBot }
	end
	local result = Liveboard.compute(views, true)
	WorldService.setLeader(if result.top[1] then result.top[1].alias else nil)
	local top = {}
	local parts = {}
	for _, entry in result.top do
		table.insert(top, {
			id = entry.id,
			alias = entry.alias,
			score = entry.score,
			bot = if entry.isBot then true else nil,
		})
		table.insert(parts, entry.id .. ":" .. entry.alias .. ":" .. entry.score)
	end
	local base = table.concat(parts, ",")
	for player, simId in simIds do
		local rank = result.ranks[simId]
		local you = if rank ~= nil then { rank = rank, score = result.scores[simId] } else nil
		local signature = base .. "|" .. (if you then you.rank .. ":" .. you.score else "-")
		if sentLiveboard[player] ~= signature then
			sentLiveboard[player] = signature
			replication:send(player, { kind = "Liveboard", top = top, you = you })
		end
	end
	for player in sentLiveboard do
		if simIds[player] == nil then
			sentLiveboard[player] = nil
		end
	end
end

RunService.Heartbeat:Connect(function(dt: number)
	accumulator += dt
	local steps = 0
	while accumulator >= STEP and steps < MAX_STEPS_PER_FRAME do
		accumulator -= STEP
		steps += 1
		-- kodiak `real_players_live`: oyundaki gerçek oyuncu sayısı.
		local realPlayersLive = 0
		for _ in simIds do
			realPlayersLive += 1
		end
		local started = os.clock()
		BotRepo.step(bots, sim, realPlayersLive)
		local ms = (os.clock() - started) * 1000
		stepStats.steps += 1
		stepStats.totalMs += ms
		stepStats.maxMs = math.max(stepStats.maxMs, ms)
	end
	if accumulator > STEP * MAX_STEPS_PER_FRAME then
		accumulator = 0
	end
	if steps > 0 then
		local replStarted = os.clock()
		replication:update(sim)
		local replMs = (os.clock() - replStarted) * 1000
		stepStats.replSteps += 1
		stepStats.replMs += replMs
		stepStats.replMaxMs = math.max(stepStats.replMaxMs, replMs)
	end
	if steps > 0 then
		AccountRewards.step(sim, simIds, steps * STEP)
	end
	InventoryService.step(simIds, dt)
	liveboardTimer += steps * STEP
	if liveboardTimer >= LIVEBOARD_PERIOD then
		liveboardTimer = 0
		sendLiveboard()
	end
end)

print(string.format("[robgame] server started (sim %d Hz)", Ticks.FREQUENCY_HZ))
