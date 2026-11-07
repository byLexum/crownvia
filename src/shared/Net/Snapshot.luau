--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: server/src/service.rs (get_game_update), client/src/game.rs (supply line drawing)

-- Oyuncu başına durum farkı (Delta) üretimi. Saf Luau: Roblox'a dokunmaz, Lune ile test edilir.
-- Sunucudaki `Replication` yalnız bunu çağırıp RemoteEvent ile gönderir.
-- Kiomet'te karşılığı `TowerService::get_game_update` + kodiak aktör modeli farkları.
-- Bilinçli sapma: görünürlük sunucuda kule bazında filtrelenir (Sim/Visibility).
-- Paket biçimi: docs/API.md

local Alerts = require("../Sim/Alerts")
local Force = require("../Sim/Force")
local Game = require("../Sim/Game")
local TowerTypeId = require("../Sim/TowerTypeId")
local Unit = require("../Sim/Unit")
local Units = require("../Sim/Units")
local Visibility = require("../Sim/Visibility")
local World = require("../Sim/World")

type Game = Game.Game
type Force = Force.Force

export type TowerRecord = {
	id: number,
	t: number, -- towerType
	o: number, -- sahip (0 = sahipsiz)
	d: number, -- delay tick (0 = aktif)
	u: { number }, -- birim sayıları, Unit sırasıyla (10 eleman)
	sl: { number }?, -- ikmal hattı (TowerId listesi); yalnız kendi kulelerinde, yoksa nil
}

-- Yoldaki birlik. İlerleme `p` örnek tick'teki değerdir; istemci `s` ile ileri hesaplar.
export type ForceRecord = {
	id: number,
	o: number, -- sahip (0 = zombi)
	a: number, -- şu anki kaynak kule
	b: number, -- şu anki hedef kule
	p: number, -- pathProgress (örnek tick'te)
	r: number, -- progressRequired
	s: number, -- progressPerTick
	k: number, -- örnek tick
	u: { number }, -- birim sayıları
}

-- Oyuncu kimliği: ad ve bot bilgisi (kodiak oyuncu kaydında bot ayrımı var).
export type PlayerRecord = { id: number, alias: string, bot: boolean }

export type ClientState = {
	simId: number,
	-- Son gönderilen kulelerin imzası
	sent: { [number]: string },
	-- Son gönderilen birliklerin imzası
	sentForces: { [number]: string },
	-- Son gönderilen oyuncu kimliği imzası ("ad|bot"); değişince yeniden gönderilir.
	knownPlayers: { [number]: string },
	-- Son gönderilen yaşam durumu (değişince delta gönderilir)
	lastAlive: boolean?,
	-- Son gönderilen uyarılar (değişince yeniden gönderilir).
	sentAlerts: Alerts.Alerts?,
	-- Son gönderilen kule sayıları ve ittifak imzaları.
	sentCounts: string?,
	sentAllies: string?,
	-- Menü izleyicisi: `simId` izlenen bottur; yaşam durumu, uyarı ve kule sayıları gitmez.
	spectator: boolean?,
}

local Snapshot = {}

function Snapshot.newClient(simId: number): ClientState
	return {
		simId = simId,
		sent = {},
		sentForces = {},
		knownPlayers = {},
		lastAlive = nil,
		sentAlerts = nil,
		sentCounts = nil,
		sentAllies = nil,
	}
end

-- Ana menü arkası canlı dünya: oyuncu henüz doğmadı, bir botun gördüğünü izler.
function Snapshot.newSpectator(botId: number): ClientState
	local client = Snapshot.newClient(botId)
	client.spectator = true
	return client
end

local function unitCounts(units: Units.Units): { number }
	local counts = table.create(Unit.COUNT, 0)
	for _, entry in Units.iter(units) do
		counts[entry.unit + 1] = entry.count
	end
	return counts
end

-- `viewer`: kaydı alacak oyuncu. İkmal hattı yalnız kendi kulesinde gönderilir: kaynak istemci
-- başkasının hattını çizmez (game.rs `tower.player_id == me || cheats()`) ve hat sisin
-- arkasındaki kuleleri de içerir; göndermek görüş dışı bilgiyi sızdırır.
function Snapshot.towerRecord(id: number, tower: any, viewer: number): TowerRecord
	return {
		id = id,
		t = tower.towerType,
		o = tower.playerId or 0,
		d = tower.delay or 0,
		u = unitCounts(tower.units),
		sl = if tower.supplyLine and tower.playerId == viewer
			then table.clone(tower.supplyLine.ids)
			else nil,
	}
end

local function towerSignature(record: TowerRecord): string
	return string.format(
		"%d|%d|%d|%s|%s",
		record.t,
		record.o,
		record.d,
		table.concat(record.u, ","),
		if record.sl then table.concat(record.sl, ",") else ""
	)
end

local function forceRecord(force: Force, tick: number): ForceRecord
	return {
		id = force.id,
		o = force.playerId or 0,
		a = Force.currentSource(force),
		b = Force.currentDestination(force),
		p = force.pathProgress,
		r = Force.progressRequired(force),
		s = Force.progressPerTick(force),
		k = tick,
		u = unitCounts(force.units),
	}
end

-- İlerleme imzaya girmez: istemci tick'ten hesaplar. Yol parçası, hız ya da birimler değişince gönderilir.
local function forceSignature(record: ForceRecord): string
	return string.format(
		"%d|%d|%d|%d|%s",
		record.o,
		record.a,
		record.b,
		record.s,
		table.concat(record.u, ",")
	)
end

-- Görünen birlikler: görünen kuleye gelenler + görünen kuleden görünmeyen kuleye gidenler
-- (Kiomet istemcisi de böyle çizer: client/src/game.rs "inbound forces and outbound forces
-- heading to invisible towers").
local function visibleForces(
	world: World.World,
	visible: { [number]: boolean }
): { [number]: Force }
	local forces: { [number]: Force } = {}
	for id in visible do
		local tower = World.get(world, id)
		if tower ~= nil then
			for _, force in tower.inboundForces do
				forces[force.id] = force
			end
			for _, force in tower.outboundForces do
				if not visible[Force.currentDestination(force)] and forces[force.id] == nil then
					forces[force.id] = force
				end
			end
		end
	end
	-- Yoluna devam eden birlikler bir tick boyunca bekleme listesindedir (`tick_after_inputs`);
	-- istemcide kaybolup görünmesinler diye onlar da dahil edilir.
	for _, event in world.pendingForces do
		if event.kind == "inbound" then
			local force = event.force
			if visible[event.towerId] or visible[Force.currentSource(force)] then
				forces[force.id] = force
			end
		end
	end
	return forces
end

-- Bir oyuncu için Delta mesajı; değişen bir şey yoksa nil.
function Snapshot.build(client: ClientState, game: Game): { [string]: any }?
	local world = game.world
	local data = game.players[client.simId]
	local visible: { [number]: boolean } = if data
		then Visibility.visibleTowers(world, data.towers)
		else {}

	local changed: { TowerRecord } = {}
	local hidden: { number } = {}
	local destroyed: { number } = {}
	local players: { PlayerRecord } = {}
	local forces: { ForceRecord } = {}
	local removedForces: { number } = {}

	-- Oyuncunun adı ya da bot bilgisi değiştiyse (ör. bot aynı kimlikle yeni adla doğdu) yeniden gönder.
	local function notePlayer(owner: number)
		if owner == 0 then
			return
		end
		local ownerData = game.players[owner]
		if ownerData == nil then
			return
		end
		local sig = ownerData.alias .. "|" .. tostring(ownerData.isBot)
		if client.knownPlayers[owner] ~= sig then
			client.knownPlayers[owner] = sig
			table.insert(players, { id = owner, alias = ownerData.alias, bot = ownerData.isBot })
		end
	end

	for id in visible do
		local tower = World.get(world, id) :: any
		local record = Snapshot.towerRecord(id, tower, client.simId)
		local sig = towerSignature(record)
		if client.sent[id] ~= sig then
			client.sent[id] = sig
			table.insert(changed, record)
		end
		notePlayer(record.o)
	end

	for id in client.sent do
		if not visible[id] then
			client.sent[id] = nil
			-- Görüşten çıkan kule ile yok edilen kule ayrı bildirilir (karar §13.2).
			if World.contains(world, id) then
				table.insert(hidden, id)
			else
				table.insert(destroyed, id)
			end
		end
	end

	local inView = visibleForces(world, visible)
	for id, force in inView do
		local record = forceRecord(force, world.tick)
		local sig = forceSignature(record)
		if client.sentForces[id] ~= sig then
			client.sentForces[id] = sig
			table.insert(forces, record)
		end
		notePlayer(record.o)
	end
	for id in client.sentForces do
		if inView[id] == nil then
			client.sentForces[id] = nil
			table.insert(removedForces, id)
		end
	end

	local alive = data ~= nil and data.alive
	local spectator = client.spectator == true
	local aliveChanged = not spectator and client.lastAlive ~= alive
	client.lastAlive = alive

	-- `NonActor::alerts`: yalnız değişince.
	local alerts: Alerts.Alerts? = nil
	if data ~= nil and alive and not spectator then
		local sentAlerts = client.sentAlerts
		if sentAlerts == nil or not Alerts.equals(sentAlerts, data.alerts) then
			alerts = Alerts.clone(data.alerts)
			client.sentAlerts = alerts
		end
	end

	-- `NonActor::tower_counts`: yükseltme ön koşulları için (dizi, indeks = tip + 1).
	local towerCounts: { number }? = nil
	if data ~= nil and alive and not spectator then
		local counts = table.create(TowerTypeId.COUNT, 0)
		for towerType, count in data.towerCounts do
			counts[towerType + 1] = count
		end
		local sig = table.concat(counts, ",")
		if client.sentCounts ~= sig then
			client.sentCounts = sig
			towerCounts = counts
		end
	end

	-- İttifaklar: `allies` = benim isteklerim, `incoming` = bana istek gönderenler
	-- (kaynakta istemci tüm oyuncuların `allies` kümesini görür; bizde yalnız beni ilgilendiren).
	local allies: { number }? = nil
	local incoming: { number }? = nil
	local actor = world.players[client.simId]
	if actor ~= nil and not spectator then
		local mine, theirs = {}, {}
		for id in actor.allies do
			table.insert(mine, id)
		end
		for id, other in world.players do
			if id ~= client.simId and other.allies[client.simId] then
				table.insert(theirs, id)
			end
		end
		table.sort(mine)
		table.sort(theirs)
		local sig = table.concat(mine, ",") .. "|" .. table.concat(theirs, ",")
		if client.sentAllies ~= sig then
			client.sentAllies = sig
			allies, incoming = mine, theirs
			for _, id in mine do
				notePlayer(id)
			end
			for _, id in theirs do
				notePlayer(id)
			end
		end
	end

	if
		not aliveChanged
		and towerCounts == nil
		and allies == nil
		and #changed == 0
		and #hidden == 0
		and #destroyed == 0
		and #players == 0
		and #forces == 0
		and #removedForces == 0
		and alerts == nil
	then
		return nil
	end

	return {
		kind = "Delta",
		tick = world.tick,
		alive = if spectator then nil else alive,
		-- `DeathReason::RulerKilled { alias, unit }` (ölüyken)
		death = if not alive
				and not spectator
				and data
				and data.deathReason
			then { alias = data.deathReason.alias, unit = data.deathReason.unit }
			else nil,
		towers = changed,
		hidden = hidden,
		destroyed = destroyed,
		players = players,
		forces = forces,
		removedForces = removedForces,
		alerts = alerts,
		towerCounts = towerCounts,
		allies = allies,
		incoming = incoming,
	}
end

return table.freeze(Snapshot)
