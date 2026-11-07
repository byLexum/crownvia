--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: server/src/service.rs, server/src/world.rs

-- Kiomet'te `server/src/service.rs` `TowerService` (oyuncu verisi, tick düzeni, olay işleme)
-- ve `server/src/world.rs` `spawn_player`, `kill_player`, `shrink` → bizde bu modül.
-- Saf Luau: Roblox'a dokunmaz. Rastgelelik dışarıdan verilir (`rng(): number`, [0, 1)).
--
-- Tick düzeni (kodiak sahne döngüsü + TowerService):
--   1. Komutlar (oyuncu ve bot)              ← kodiak girdileri
--   2. TowerService::tick                    ← skor, tower_counts; World::tick_after_inputs
--   3. TowerService::post_update             ← ölüleri öldür, 8 sn'de küçült, World::tick_before_inputs
-- `Game.step` bu sırayı uygular; komutlar `Game.step`'ten önce doğrudan çağrılır.

local Actions = require("./Actions")
local Alerts = require("./Alerts")
local Info = require("./Info")
local Path = require("./Path")
local Spawn = require("./Spawn")
local Ticks = require("./Ticks")
local Tower = require("./Tower")
local TowerTick = require("./TowerTick")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local TowerTypeId = require("./TowerTypeId")
local Unit = require("./Unit")
local Units = require("./Units")
local World = require("./World")

type World = World.World
type TowerId = TowerId.TowerId
type Ticks = Ticks.Ticks
type InfoEvent = Info.InfoEvent

-- `PlayerData` (service.rs)
export type PlayerData = {
	alive: boolean,
	score: number,
	alias: string,
	isBot: boolean,
	towers: { [TowerId]: boolean },
	-- Doygunluklu sayaç: ne kadar yaşadı.
	lifetime: Ticks,
	-- Yalnız aktif kuleler sayılır (u16'ya kırpılır).
	towerCounts: { [number]: number },
	deathReason: Info.DeathReason?,
	-- Öldürülen kral sayısı. Yalnız hesap ilerlemesi okur, kuralları etkilemez (kaynakta yok).
	kings: number,
	-- Hesap katmanı için (kural değil): son öldürdüğüm oyuncu, beni öldüren oyuncu.
	lastVictim: number?,
	killedBy: number?,
	-- Saniyede bir hesaplanan uyarılar (`PlayerData::alerts`).
	alerts: Alerts.Alerts,
}

export type Game = {
	world: World,
	players: { [number]: PlayerData },
	maybeDead: { [number]: boolean },
	-- Öldürüldükten sonra verisi silinecek (Roblox'tan ayrıldı).
	leaving: { [number]: boolean },
	nextPlayerId: number,
	rng: () -> number,
	-- Dışarıya (ağ katmanına) iletilecek olaylar.
	onInfo: ((InfoEvent) -> ())?,
}

-- `Command` (common/src/protocol.rs). `SetViewport` istemciye özgü; burada yok.
export type Command =
	{ kind: "Spawn", alias: string }
	| { kind: "DeployForce", towerId: TowerId, path: { TowerId } }
	| { kind: "SetSupplyLine", towerId: TowerId, path: { TowerId }? }
	| { kind: "Upgrade", towerId: TowerId, towerType: number }
	| { kind: "Alliance", with: number, breakAlliance: boolean }

local Game = {}

local MAX_SPAWN_TRIES = 100000

-- `TowerService::new`
function Game.new(rng: () -> number): Game
	return {
		world = World.new(),
		players = {},
		maybeDead = {},
		leaving = {},
		nextPlayerId = 1,
		rng = rng,
		onInfo = nil,
	}
end

local function newPlayerData(isBot: boolean): PlayerData
	return {
		alive = false,
		score = 0,
		alias = "",
		isBot = isBot,
		towers = {},
		lifetime = Ticks.ZERO,
		towerCounts = {},
		deathReason = nil,
		kings = 0,
		lastVictim = nil,
		killedBy = nil,
		alerts = Alerts.new(),
	}
end

-- `TowerService::on_info_event`: oyuncu verisini olaylarla günceller.
local function handleInfo(game: Game, event: InfoEvent)
	if event.kind == "GainedTower" then
		local player = game.players[event.playerId]
		assert(player ~= nil, "GainedTower: missing player")
		if event.reason == "Spawned" then
			assert(not player.alive, "spawning player should not be alive")
			player.alive = true
		end
		assert(not player.towers[event.towerId], "GainedTower: tower already in set")
		player.towers[event.towerId] = true
	elseif event.kind == "LostRuler" then
		local player = game.players[event.playerId]
		assert(player ~= nil, "LostRuler: missing player")
		local killer = if event.killedBy ~= nil then game.players[event.killedBy] else nil
		player.deathReason = { alias = if killer then killer.alias else nil, unit = event.unit }
		player.killedBy = event.killedBy
		if killer and killer ~= player then
			killer.kings += 1
			killer.lastVictim = event.playerId
		end
		game.maybeDead[event.playerId] = true
	elseif event.kind == "LostTower" then
		local player = game.players[event.playerId]
		assert(player ~= nil, "LostTower: missing player")
		assert(player.towers[event.towerId], "LostTower: tower not in set")
		player.towers[event.towerId] = nil
	end
	if game.onInfo then
		game.onInfo(event)
	end
end

function Game.infoHandler(game: Game): (InfoEvent) -> ()
	return function(event: InfoEvent)
		handleInfo(game, event)
	end
end

-- `ArenaService::player_joined`. Sim oyuncu id'si döner.
function Game.playerJoined(game: Game, isBot: boolean): number
	local playerId = game.nextPlayerId
	game.nextPlayerId += 1
	game.players[playerId] = newPlayerData(isBot)
	game.world.players[playerId] = { allies = {}, newAlliances = {} }
	return playerId
end

-- `ArenaService::player_quit`: bir sonraki `post_update`'te öldürülür.
-- Roblox'ta oyuncu ayrıldığı an çağrılır (kaynaktaki 30 sn LIMBO yok; bilinçli sapma).
function Game.playerQuit(game: Game, playerId: number)
	game.maybeDead[playerId] = true
	game.leaving[playerId] = true
end

-- kodiak `BotRepo::post_update` `BotAction::Quit`: `player_quit` çağrılır ama bot aynı yuvada
-- hemen yeniden katılır (regulator `WaitingToLeave → Joined`), `player_left` çağrılmaz.
-- Sonuç: bot bir sonraki `post_update`'te ölür, verisi kalır, sonra yeniden doğar.
function Game.botQuit(game: Game, playerId: number)
	game.maybeDead[playerId] = true
end

-- `ArenaService::player_left`
local function playerLeft(game: Game, playerId: number)
	game.players[playerId] = nil
	game.world.players[playerId] = nil
end

-- `TowerService::is_spawnable`
function Game.isSpawnable(game: Game, id: TowerId): boolean
	return Spawn.isSpawnable(game.world, id)
end

-- `TowerService::spawn_player` (`Command::Spawn`). Hata mesajı ya da nil döner.
function Game.spawnPlayer(game: Game, playerId: number, alias: string): string?
	local player = game.players[playerId]
	if player == nil then
		return "non-existent player"
	end
	if player.alive then
		return "already alive"
	end
	player.alias = alias

	local world = game.world
	local governor = MAX_SPAWN_TRIES
	-- Kule² cinsinden alan → kule cinsinden yarıçap (u16'ya kesilir).
	local searchRadius = math.floor(math.sqrt(100 * (1 / math.pi)))
	local centerX, centerY = TowerId.x(TowerId.CENTER), TowerId.y(TowerId.CENTER)
	local maxCoord = TowerId.WORLD_SIZE - 1

	local spawnId: TowerId? = nil
	while true do
		if governor == 0 then
			return "couldn't find spawnable tower"
		end
		governor -= 1

		-- kodiak `gen_radius`: rastgele açı, sqrt(u) * yarıçap.
		local angle = game.rng() * 2 * math.pi
		local distance = math.sqrt(game.rng()) * searchRadius
		local x = math.clamp(math.floor(math.cos(angle) * distance + centerX + 0.5), 0, maxCoord)
		local y = math.clamp(math.floor(math.sin(angle) * distance + centerY + 0.5), 0, maxCoord)
		local candidate = TowerId.new(x, y)

		if Spawn.isSpawnable(world, candidate) then
			player.lifetime = Ticks.ZERO
			player.deathReason = nil
			player.score = 0
			player.alerts = Alerts.new()
			spawnId = candidate
			break
		end

		if governor % 8 == 0 then
			searchRadius += 1
		end
	end
	local towerId = spawnId :: TowerId

	local onInfo = Game.infoHandler(game)

	-- Doğuş noktası ve baloncuğu (merkeze giden yol dahil) üretilir.
	local set: { [TowerId]: boolean } = {}
	Spawn.spawnBubble(towerId, player.isBot, function(id)
		Spawn.traverse(world, set, id)
	end)
	local toGenerate = {}
	for id in set do
		table.insert(toGenerate, id)
	end
	table.sort(toGenerate)
	Actions.generate(world, toGenerate)

	Actions.spawn(world, towerId, playerId, onInfo)

	for _, neighbor in TowerId.neighbors(towerId) do
		Actions.clearZombies(world, neighbor)
	end
	return nil
end

-- `TowerService::kill_player`
function Game.killPlayer(game: Game, playerId: number)
	local player = game.players[playerId]
	assert(player ~= nil, "killPlayer: missing player")
	player.alive = false

	Actions.killPlayer(game.world, playerId, Game.infoHandler(game))

	local actor = game.world.players[playerId]
	if actor ~= nil then
		for allyId in actor.allies do
			local ally = game.world.players[allyId]
			if ally ~= nil then
				-- `PlayerMaintainance::RemoveDeadAlly`
				ally.allies[playerId] = nil
			end
		end
		-- `PlayerMaintainance::Died`
		table.clear(actor.allies)
	end

	assert(next(player.towers) == nil, "killPlayer: player still has towers")
end

-- `TowerService::shrink`: sahipsiz ve korunmayan kuleleri siler.
function Game.shrink(game: Game)
	local world = game.world
	local locked: { [TowerId]: boolean } = {}
	local function lockToCenter(start: TowerId)
		local t = start
		while not locked[t] do
			locked[t] = true
			t = TowerId.connectivityId(t) :: TowerId
		end
	end

	for _, id in World.ids(world) do
		local tower = world.towers[id]
		if not Tower.canDestroy(tower) then
			lockToCenter(id)
			-- Kralın çevresindeki baloncuk korunur.
			for _, rulerPlayerId in Tower.iterRulers(tower) do
				local ruler = game.players[rulerPlayerId]
				local isBot = ruler ~= nil and ruler.isBot
				Spawn.spawnBubble(id, isBot, function(t)
					if World.contains(world, t) then
						lockToCenter(t)
					end
				end)
			end
		end
	end

	local toDestroy = {}
	for _, id in World.ids(world) do
		if not locked[id] then
			table.insert(toDestroy, id)
		end
	end
	Actions.destroy(world, toDestroy)
end

-- `TowerService::tick`: yaşam süresi, saniyede bir skor, kule sayıları ve uyarılar.
local function serviceTick(game: Game)
	local world = game.world
	local counter = world.tick
	for playerId, player in game.players do
		if player.alive then
			player.lifetime = Ticks.saturatingAdd(player.lifetime, Ticks.ONE)
			if Ticks.every(counter, Ticks.fromWholeSecs(1)) then
				local score = 0
				local counts: { [number]: number } = {}
				local alerts = player.alerts
				Alerts.resetEphemeral(alerts)
				-- Aksi kanıtlanana kadar kral güvende değil sayılır.
				local flags = bit32.bor(alerts.flags, Alerts.RulerNotSafe)
				local ids = {}
				for id in player.towers do
					table.insert(ids, id)
				end
				table.sort(ids)
				for _, id in ids do
					local tower = World.get(world, id)
					assert(tower ~= nil, "serviceTick: missing tower")
					flags = Alerts.updateTower(alerts, flags, world, playerId, id, tower)
					if Tower.active(tower) then
						score += TowerType.scoreWeight(tower.towerType)
						counts[tower.towerType] =
							math.min((counts[tower.towerType] or 0) + 1, 65535)
					end
				end
				alerts.flags = flags
				player.score = score
				player.towerCounts = counts
			end
		end
	end
	-- `World::tick_after_inputs`: chunk olayları (yeni birlikler) uygulanır.
	World.applyPendingForces(world)
end

-- `World::tick_before_inputs`: tick sayacı → durdurmalar → yeni ittifakları temizle → kule tick'leri.
local function worldTickBeforeInputs(game: Game)
	local world = game.world
	world.tick = Ticks.next(world.tick)
	TowerTick.halt(world)
	for _, actor in world.players do
		table.clear(actor.newAlliances)
	end
	TowerTick.tickAll(world, Game.infoHandler(game))
end

-- `TowerService::post_update`
local function postUpdate(game: Game)
	local dead = game.maybeDead
	game.maybeDead = {}
	local deadIds = {}
	for playerId in dead do
		table.insert(deadIds, playerId)
	end
	table.sort(deadIds)
	for _, playerId in deadIds do
		if game.players[playerId] ~= nil then
			Game.killPlayer(game, playerId)
		end
		if game.leaving[playerId] then
			game.leaving[playerId] = nil
			playerLeft(game, playerId)
		end
	end

	if Ticks.every(Ticks.next(game.world.tick), Ticks.fromWholeSecs(8)) then
		Game.shrink(game)
	end

	worldTickBeforeInputs(game)
end

-- Bot karar sırası için ayrık: kodiak sahnesi `tick` → bot kararları → `post_update` → bot komutları.
Game.tick = serviceTick
Game.postUpdate = postUpdate

-- Bir simülasyon adımı (250 ms). Komutlar bundan önce uygulanmış olmalı.
function Game.step(game: Game)
	serviceTick(game)
	postUpdate(game)
end

-- `TowerService::set_supply_line`. `pathIds` nil → hattı kaldır. Hata mesajı ya da nil döner.
function Game.setSupplyLineInner(
	game: Game,
	playerId: number,
	towerId: TowerId,
	pathIds: { TowerId }?
): string?
	local world = game.world
	local tower = World.get(world, towerId)
	if tower == nil then
		return "no tower"
	end
	if tower.playerId ~= playerId then
		return "source not under player's control"
	end
	if not Tower.generatesMobileUnits(tower) then
		return "invalid supply line"
	end
	local path: Path.Path? = nil
	if pathIds ~= nil then
		if #pathIds < 2 then
			return "path too short"
		end
		local candidate = Path.new(pathIds)
		local ok, err = Path.validate(candidate, function(id)
			return World.contains(world, id)
		end, towerId, TowerType.rangedDistance(tower.towerType))
		if not ok then
			return err
		end
		-- Aynı hat tekrar gönderilirse kaldırılır (`.filter(|p| Some(p) != tower.supply_line)`).
		local current = tower.supplyLine
		if current == nil or not Path.equals(candidate, current) then
			path = candidate
		end
	end
	local player = game.players[playerId]
	if player ~= nil and not player.isBot then
		Alerts.set(
			player.alerts,
			if path ~= nil then Alerts.SetAnySupplyLine else Alerts.UnsetAnySupplyLine
		)
	end
	-- `ChunkInput::SetSupplyLine`
	tower.supplyLine = path
	return nil
end

-- `Command::SetSupplyLine` (service.rs `player_command`): hat verilmişse ve kuledeki hareketli
-- birimlerin hepsinin menzili kulenin menziliyle aynıysa, önce o yola birlik de gönderilir.
function Game.setSupplyLine(
	game: Game,
	playerId: number,
	towerId: TowerId,
	pathIds: { TowerId }?
): string?
	local tower = World.get(game.world, towerId)
	if pathIds ~= nil and tower ~= nil then
		local maxEdgeDistance = TowerType.rangedDistance(tower.towerType)
		local mobile = false
		local matches = true
		for _, entry in Units.iter(tower.units) do
			if Unit.isMobile(entry.unit, tower.towerType) then
				mobile = true
				-- Nükleer ikmal hattına asker vb. gönderme.
				if Unit.rangedDistance(entry.unit) ~= maxEdgeDistance then
					matches = false
					break
				end
			end
		end
		if mobile and matches then
			local err = Game.deployForce(game, playerId, towerId, pathIds)
			if err ~= nil then
				return "SetSupplyLine/DeployForce resulted in " .. err
			end
		end
	end
	return Game.setSupplyLineInner(game, playerId, towerId, pathIds)
end

-- `TowerService::deploy_force` (`Command::DeployForce`). Hata mesajı ya da nil döner.
-- `pathIds`: istemciden gelen ham liste; burada tip ve uzunluk da doğrulanır.
function Game.deployForce(
	game: Game,
	playerId: number,
	towerId: TowerId,
	pathIds: { TowerId }
): string?
	local world = game.world
	local tower = World.get(world, towerId)
	if tower == nil then
		return "no tower"
	end
	if tower.playerId ~= playerId then
		return "source not under player's control"
	end
	local strength = Tower.forceUnits(tower)
	if Units.isEmpty(strength) then
		return "empty force"
	end
	if #pathIds < 2 then
		return "path too short"
	end
	local path = Path.new(pathIds)
	local ok, err = Path.validate(path, function(id)
		return World.contains(world, id)
	end, towerId, Units.maxEdgeDistance(strength))
	if not ok then
		return err
	end
	local player = game.players[playerId]
	if player ~= nil and not player.isBot then
		Alerts.set(player.alerts, Alerts.DeployedAnyForce)
	end
	World.queueForces(world, Tower.deployForce(tower, path))
	return nil
end

-- `TowerService::upgrade_tower` (server/src/world.rs): yükseltme ya da `basis`'e geri düşürme.
function Game.upgradeTower(game: Game, playerId: number, towerId: TowerId, upgrade: number): string?
	if
		type(upgrade) ~= "number"
		or upgrade ~= math.floor(upgrade)
		or upgrade < 0
		or upgrade >= TowerTypeId.COUNT
	then
		return "malformed tower type"
	end
	local tower = World.get(game.world, towerId)
	if tower == nil then
		return "cannot upgrade nonexistent tower"
	end
	if tower.playerId ~= playerId then
		return "cannot upgrade tower not owned"
	end
	if not Tower.active(tower) then
		return "upgrade already pending"
	end
	local player = game.players[playerId]
	if player == nil then
		return "nonexistent player"
	end
	if TowerType.canUpgradeTo(tower.towerType, upgrade) then
		if not TowerType.hasPrerequisites(upgrade, player.towerCounts) then
			return "missing prerequisite"
		end
		Alerts.set(player.alerts, Alerts.UpgradedAnyTower)
	elseif TowerType.basis(tower.towerType) ~= upgrade then
		return "invalid upgrade path"
	end
	Actions.upgradeTower(game.world, towerId, upgrade)
	return nil
end

-- `TowerService::alliance` (server/src/world.rs). Tek yönlü istek; iki taraf da istediğinde ittifak
-- kurulur ve o tick'te iki tarafa `NewAlliance` yazılır (birlikleri durdurmak için, `halt`).
-- Bozma iki yönlüdür. Kaynaktaki gibi kendine istek gönderme engellenmez.
function Game.alliance(game: Game, playerId: number, with: number, breakAlliance: boolean): string?
	if game.players[playerId] == nil then
		return "non-existent player"
	end
	if type(with) ~= "number" or game.players[with] == nil then
		return "alliance with inactive player"
	end
	local world = game.world
	local newAlliance = not breakAlliance
		and not World.player(world, playerId).allies[with]
		and World.player(world, with).allies[playerId] == true

	if newAlliance then
		-- `PlayerInput::NewAlliance`
		World.player(world, playerId).newAlliances[with] = true
		World.player(world, with).newAlliances[playerId] = true
	end

	if breakAlliance then
		-- `PlayerInput::RemoveAlly`, iki yönde.
		World.player(world, playerId).allies[with] = nil
		World.player(world, with).allies[playerId] = nil
	else
		-- `PlayerInput::AddAlly`, yalnız istek yönünde.
		World.player(world, playerId).allies[with] = true
	end
	return nil
end

-- `TowerService::player_command` (server/src/service.rs): tek giriş noktası, oyuncu ve bot aynı.
-- Hata mesajı ya da nil döner.
function Game.command(game: Game, playerId: number, command: Command): string?
	local err: string?
	if command.kind == "Spawn" then
		err = Game.spawnPlayer(game, playerId, command.alias)
	elseif command.kind == "DeployForce" then
		err = Game.deployForce(game, playerId, command.towerId, command.path)
	elseif command.kind == "SetSupplyLine" then
		err = Game.setSupplyLine(game, playerId, command.towerId, command.path)
	elseif command.kind == "Upgrade" then
		err = Game.upgradeTower(game, playerId, command.towerId, command.towerType)
	elseif command.kind == "Alliance" then
		err = Game.alliance(game, playerId, command.with, command.breakAlliance)
	else
		err = "unknown command"
	end
	if err ~= nil then
		return command.kind .. " resulted in " .. err
	end
	return nil
end

-- Testler/istemci için: oyuncunun kral kulesi.
function Game.rulerTower(game: Game, playerId: number): TowerId?
	local player = game.players[playerId]
	if player == nil then
		return nil
	end
	for id in player.towers do
		local tower = World.get(game.world, id)
		if tower and Units.hasRuler(tower.units) then
			return id
		end
	end
	return nil
end

return table.freeze(Game)
