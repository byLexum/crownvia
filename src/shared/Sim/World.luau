--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/world.rs, common/src/world/towers.rs, common/src/player.rs, common/src/singleton.rs

-- Kiomet'te `common/src/world.rs` `World` (kodiak aktör modeli: chunk + player + singleton)
-- → bizde bu modül. Chunk'lar taşınmaz: kuleler tek tabloda (TowerId → Tower).
-- Kaynaktaki iterasyon sırası korunur: chunk'lar (önce cy, sonra cx), chunk içinde
-- kuleler (önce y, sonra x). Bu sıra tick sonucunu etkiler.

local Force = require("./Force")
local Ticks = require("./Ticks")
local Tower = require("./Tower")
local TowerId = require("./TowerId")

type Force = Force.Force
type Tower = Tower.Tower
type TowerId = TowerId.TowerId
type Ticks = Ticks.Ticks

-- `common/src/player.rs` `struct Player` (aktör)
export type PlayerActor = {
	allies: { [number]: boolean },
	newAlliances: { [number]: boolean },
}

export type World = {
	towers: { [TowerId]: Tower },
	-- Sıralı id listesi önbelleği (nil → yeniden hesaplanır).
	order: { TowerId }?,
	players: { [number]: PlayerActor },
	-- `Singleton::tick`
	tick: Ticks,
	-- `ChunkEvent`'ler: girdilerden sonra uygulanır (`tick_after_inputs`).
	pendingForces: { Tower.ForceEvent },
}

local World = {}

World.CENTER = TowerId.CENTER

local CHUNK = TowerId.CHUNK_SIZE
local CHUNKS = TowerId.WORLD_SIZE // CHUNK

-- Kaynaktaki iterasyon sırası anahtarı: (cy, cx, ly, lx)
local function orderKey(id: TowerId): number
	local x, y = TowerId.x(id), TowerId.y(id)
	local cx, cy = x // CHUNK, y // CHUNK
	return ((cy * CHUNKS + cx) * CHUNK + (y % CHUNK)) * CHUNK + (x % CHUNK)
end

-- `World::new`
function World.new(): World
	return {
		towers = {},
		order = nil,
		players = {},
		tick = Ticks.ZERO,
		pendingForces = {},
	}
end

-- `WorldChunks::get`
function World.get(world: World, id: TowerId): Tower?
	return world.towers[id]
end

-- `WorldChunks::contains`: kule üretilmiş mi.
function World.contains(world: World, id: TowerId): boolean
	return world.towers[id] ~= nil
end

-- `Chunk::insert`: zaten varsa hata (kaynakta panik).
function World.insert(world: World, id: TowerId, tower: Tower)
	assert(world.towers[id] == nil, "World.insert: tower already exists")
	world.towers[id] = tower
	world.order = nil
end

-- `Chunk::remove`: yoksa hata (kaynakta panik).
function World.remove(world: World, id: TowerId): Tower
	local tower = world.towers[id]
	assert(tower ~= nil, "World.remove: tower does not exist")
	world.towers[id] = nil
	world.order = nil
	return tower
end

-- `WorldChunks::iter_towers` sırası.
function World.ids(world: World): { TowerId }
	local order = world.order
	if order == nil then
		local list = {}
		for id in world.towers do
			table.insert(list, id)
		end
		table.sort(list, function(a, b)
			return orderKey(a) < orderKey(b)
		end)
		world.order = list
		return list
	end
	return order
end

-- `World::player` (aktör). Yoksa hata (kaynakta panik).
function World.player(world: World, playerId: number): PlayerActor
	local player = world.players[playerId]
	assert(player ~= nil, "World.player: missing player")
	return player
end

-- `World::have_alliance`: iki yönlü istek varsa ittifak.
function World.haveAlliance(world: World, a: number, b: number): boolean
	return World.player(world, a).allies[b] == true and World.player(world, b).allies[a] == true
end

-- `self.extend(context.into_events())`: chunk olaylarını sıraya al.
function World.queueForces(world: World, events: { Tower.ForceEvent })
	for _, event in events do
		table.insert(world.pendingForces, event)
	end
end

-- `ChunkEvent::AddInboundForce / AddOutboundForce` uygulaması (`tick_after_inputs`).
function World.applyPendingForces(world: World)
	local pending = world.pendingForces
	world.pendingForces = {}
	for _, event in pending do
		local tower = world.towers[event.towerId]
		assert(tower ~= nil, "applyPendingForces: missing destination tower")
		if event.kind == "inbound" then
			table.insert(tower.inboundForces, event.force)
		else
			table.insert(tower.outboundForces, event.force)
		end
	end
end

return table.freeze(World)
