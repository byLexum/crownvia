--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: server/src/world.rs

-- Kiomet'te `server/src/world.rs` içindeki `is_spawnable`, `is_good_spawn`, `is_safe_spawn`,
-- `spawn_bubble`, `bubble`, `traverse` → bizde bu modül. Saf Luau (Lune ile test edilir).

local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local World = require("./World")

type World = World.World
type TowerId = TowerId.TowerId

local Spawn = {}

-- `bubble`: `origin` çevresinde, dünya koordinatında `radius` içindeki kuleler (BFS, yol üzerinden).
function Spawn.bubble(origin: TowerId, radius: number, f: (TowerId) -> ())
	local seen: { [TowerId]: boolean } = { [origin] = true }
	local queue: { [number]: TowerId } = { origin }
	local head, tail = 1, 1
	local r2 = radius * radius
	f(origin)
	while head <= tail do
		local id = queue[head]
		queue[head] = nil
		head += 1
		for _, neighbor in TowerId.neighbors(id) do
			if TowerId.distanceSquared(neighbor, origin) <= r2 and not seen[neighbor] then
				seen[neighbor] = true
				tail += 1
				queue[tail] = neighbor
				f(neighbor)
			end
		end
	end
end

-- `spawn_bubble`: bot 35, oyuncu 50 dünya birimi (kaynakta release derlemesinde).
function Spawn.spawnBubble(origin: TowerId, isBot: boolean, f: (TowerId) -> ())
	Spawn.bubble(origin, if isBot then 35 else 50, f)
end

-- `traverse`: henüz üretilmemiş kulelerden merkeze doğru giden yolu `set`'e ekler.
function Spawn.traverse(world: World, set: { [TowerId]: boolean }, start: TowerId)
	local id = start
	while not World.contains(world, id) do
		if set[id] then
			break
		end
		set[id] = true
		local direction = TowerId.connectivity(id)
		assert(direction ~= nil, "traverse: tower not connected to center")
		id = TowerId.neighborUnchecked(id, direction)
	end
end

-- `is_good_spawn` içindeki `get_tower_type`: sahipliyse nil.
local function spawnTowerType(world: World, id: TowerId): number?
	local tower = World.get(world, id)
	if tower ~= nil then
		if tower.playerId ~= nil then
			return nil
		end
		return tower.towerType
	end
	return TowerId.towerType(id)
end

-- `is_good_spawn`
function Spawn.isGoodSpawn(world: World, id: TowerId): boolean
	local towerType = spawnTowerType(world, id)
	if towerType == nil then
		return false
	end
	local neighbors = 0
	local spawnableNeighbors = 0
	for _, neighborId in TowerId.neighbors(id) do
		neighbors += 1
		local neighborType = spawnTowerType(world, neighborId)
		if neighborType == nil then
			return false
		end
		if TowerType.isSpawnable(neighborType) then
			spawnableNeighbors += 1
		end
	end
	return (TowerType.isSpawnable(towerType) and neighbors >= 3) or spawnableNeighbors >= 2
end

-- `is_safe_spawn`: 4 adım içinde sahipli kule veya gelen birlik yok ve en az 12 farklı hücre.
-- Kaynaktaki tuhaflıklar birebir korunur: 64 bitlik küme (x&7, y&7) ile çakışmalı,
-- 16 elemanlı diziler `len % 16` ile üzerine yazılır.
function Spawn.isSafeSpawn(world: World, id: TowerId): boolean
	local set: { [number]: boolean } = {}
	local setCount = 0
	local function insert(other: TowerId): boolean
		local index = bit32.bor(
			bit32.band(TowerId.x(other), 7),
			bit32.lshift(bit32.band(TowerId.y(other), 7), 3)
		)
		if set[index] then
			return false
		end
		set[index] = true
		setCount += 1
		return true
	end

	local a: { TowerId } = table.create(16, 0)
	local b: { TowerId } = table.create(16, 0)
	a[1] = id
	local len = 1

	for _ = 1, 4 do
		local count = math.min(len, 16)
		len = 0
		for i = 1, count do
			for _, neighbor in TowerId.neighbors(a[i]) do
				if insert(neighbor) then
					local tower = World.get(world, neighbor)
					if tower ~= nil and (tower.playerId ~= nil or #tower.inboundForces > 0) then
						return false
					end
					b[(len % 16) + 1] = neighbor
					len += 1
				end
			end
		end
		a, b = b, a
	end
	return setCount >= 12
end

-- `is_spawnable`
function Spawn.isSpawnable(world: World, id: TowerId): boolean
	return TowerId.connectivity(id) ~= nil
		and Spawn.isGoodSpawn(world, id)
		and Spawn.isSafeSpawn(world, id)
end

return table.freeze(Spawn)
