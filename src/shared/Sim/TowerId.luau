--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/tower/id.rs, common/src/tower/connectivity.rs, common/src/tower.rs (integer_sqrt), common/src/chunk/id.rs

-- Kiomet'te `common/src/tower/id.rs` içindeki `struct TowerId(U16Vec2)`, `TowerNeighbor`,
-- `OffsetTable`, `NeighborTable` ve `tower/connectivity.rs` `ConnectivityTable` → bizde bu modül.
--
-- TowerId tek bir sayıya paketlenir: `x * 65536 + y` (x, y: u16). Böylece sayı karşılaştırması
-- Rust'taki türetilmiş `PartialOrd` (önce x, sonra y) ile aynı sırayı verir.
--
-- Hash: kaynaktaki işlem sırası birebir korunur. Bu standart FNV-1a DEĞİLDİR:
-- her baytta önce `hash = hash.wrapping_mul(FNV_PRIME)`, sonra `hash ^= byte` yapılır.

local TowerType = require("./TowerType")

export type TowerId = number
-- `TowerNeighbor` (0 = N .. 7 = NW)
export type TowerNeighbor = number

local TowerId = {}

-- `TowerId::CONVERSION`: kule hücresi başına dünya birimi.
TowerId.CONVERSION = 5
-- `WorldChunks::SIZE` (world/towers.rs)
TowerId.WORLD_SIZE = 512
-- `Chunk::SIZE` (chunk.rs)
TowerId.CHUNK_SIZE = 16
-- `World::MAX_ROAD_LENGTH` ve `MAX_ROAD_LENGTH_SQUARED` (world.rs)
TowerId.MAX_ROAD_LENGTH = 5
TowerId.MAX_ROAD_LENGTH_SQUARED = (5 + 1) ^ 2 - 1

local CONVERSION = TowerId.CONVERSION
local WORLD_SIZE = TowerId.WORLD_SIZE
local U16 = 65536
local U32 = 4294967296

local FNV_OFFSET = 2166136261
-- FNV_PRIME = 16777619 = 2^24 + 403

-- `TowerNeighbor` sırası ve yön vektörleri (`From<TowerNeighbor> for I16Vec2`).
TowerId.Neighbor = table.freeze({
	N = 0,
	NE = 1,
	E = 2,
	SE = 3,
	S = 4,
	SW = 5,
	W = 6,
	NW = 7,
})
local DX: { number } = { 0, 1, 1, 1, 0, -1, -1, -1 }
local DY: { number } = { 1, 1, 0, -1, -1, -1, 0, 1 }

-- `TowerId::new`
function TowerId.new(x: number, y: number): TowerId
	return x * U16 + y
end

function TowerId.x(id: TowerId): number
	return id // U16
end

function TowerId.y(id: TowerId): number
	return id % U16
end

function TowerId.toString(id: TowerId): string
	return string.format("(%d, %d)", id // U16, id % U16)
end

-- `wrapping_mul(FNV_PRIME)` u32 üzerinde, double taşmadan.
local function mulPrime(hash: number): number
	return (bit32.lshift(hash, 24) + hash * 403) % U32
end

-- write_u8: önce çarp, sonra XOR.
local function writeU8(hash: number, byte: number): number
	return bit32.bxor(mulPrime(hash), byte)
end

-- write_u16: little-endian.
local function writeU16(hash: number, value: number): number
	hash = writeU8(hash, value % 256)
	return writeU8(hash, value // 256)
end

-- `condense!(condense!(hash, u16), u8)`: 32 → 16 → 8 bit XOR katlama.
local function condenseToU8(hash: number): number
	local u16 = bit32.bxor(hash % U16, hash // U16)
	return bit32.bxor(u16 % 256, u16 // 256)
end

-- Testler için dışa açık: (x, y) u16 çiftinin kaynaktaki hash'i.
function TowerId.hashU16Pair(x: number, y: number): number
	return condenseToU8(writeU16(writeU16(FNV_OFFSET, x), y))
end

-- `TowerId::tower_type`: haritadaki kule tipi (31415 eklenerek OffsetTable'dan farklılaştırılır).
function TowerId.towerType(id: TowerId): number
	local x = (id // U16 + 31415) % U16
	local y = (id % U16 + 31415) % U16
	return TowerType.generate(TowerId.hashU16Pair(x, y))
end

-- `OffsetTable` (1..4 aralığında x/y kaydırma). Kaynakta önceden 512x512 hesaplanır;
-- burada ihtiyaç anında hesaplanıp önbelleğe alınır (sonuç aynı).
local offsetCache = buffer.create(WORLD_SIZE * WORLD_SIZE)
local offsetComputed = buffer.create(WORLD_SIZE * WORLD_SIZE)

local function offsetPacked(id: TowerId): number
	-- Kaynakta da `& MASK` ile maskelenir (dünya dışı id'ler için).
	local x = bit32.band(id // U16, WORLD_SIZE - 1)
	local y = bit32.band(id % U16, WORLD_SIZE - 1)
	local index = y * WORLD_SIZE + x
	if buffer.readu8(offsetComputed, index) == 0 then
		local hash = TowerId.hashU16Pair(x, y)
		local ox = bit32.band(hash, 3) + 1
		local oy = bit32.band(bit32.rshift(hash, 4), 3) + 1
		buffer.writeu8(offsetCache, index, ox + oy * 16)
		buffer.writeu8(offsetComputed, index, 1)
	end
	return buffer.readu8(offsetCache, index)
end

-- `TowerId::offset`: (ox, oy)
function TowerId.offset(id: TowerId): (number, number)
	local packed = offsetPacked(id)
	return packed % 16, packed // 16
end

-- `TowerId::integer_position`: id * CONVERSION + offset (u16)
function TowerId.integerPosition(id: TowerId): (number, number)
	local ox, oy = TowerId.offset(id)
	return ((id // U16) * CONVERSION + ox) % U16, ((id % U16) * CONVERSION + oy) % U16
end

-- `TowerId::distance_squared` (deterministik, tamsayı)
function TowerId.distanceSquared(a: TowerId, b: TowerId): number
	local ax, ay = TowerId.integerPosition(a)
	local bx, by = TowerId.integerPosition(b)
	local dx, dy = ax - bx, ay - by
	return dx * dx + dy * dy
end

-- `integer_sqrt` (tower.rs): kesin aşağı yuvarlanmış tamsayı karekök.
function TowerId.integerSqrt(value: number): number
	local root = math.floor(math.sqrt(value))
	while root * root > value do
		root -= 1
	end
	while (root + 1) * (root + 1) <= value do
		root += 1
	end
	return root
end

-- `TowerId::distance` (kesik, deterministik)
function TowerId.distance(a: TowerId, b: TowerId): number
	return TowerId.integerSqrt(TowerId.distanceSquared(a, b))
end

-- `TowerId::manhattan_distance`
function TowerId.manhattanDistance(a: TowerId, b: TowerId): number
	return math.abs(a // U16 - b // U16) + math.abs(a % U16 - b % U16)
end

-- `WorldChunks::RECTANGLE.contains`
function TowerId.inWorld(id: TowerId): boolean
	return id // U16 < WORLD_SIZE and id % U16 < WORLD_SIZE
end

-- `TowerId::is_valid` (kaynakta `<=`, aynen korundu)
function TowerId.isValid(id: TowerId): boolean
	return id // U16 <= WORLD_SIZE and id % U16 <= WORLD_SIZE
end

-- `(self.0.as_i16vec2() + I16Vec2::from(neighbor)).as_u16vec2()`: u16 sarmalı komşu id.
local function rawNeighbor(id: TowerId, neighbor: TowerNeighbor): TowerId
	local x = (id // U16 + DX[neighbor + 1]) % U16
	local y = (id % U16 + DY[neighbor + 1]) % U16
	return x * U16 + y
end

-- `NeighborTable::new` içindeki `are_neighbors`
local function areNeighbors(a: TowerId, b: TowerId): boolean
	if a == b or not TowerId.inWorld(b) then
		return false
	end
	local distance = TowerId.distanceSquared(a, b)
	if distance > TowerId.MAX_ROAD_LENGTH_SQUARED then
		return false
	end
	local ax, ay = a // U16, a % U16
	local bx, by = b // U16, b % U16
	if bx ~= ax and by ~= ay then
		-- Çapraz yol, kendisini kesen daha kısa çaprazı engellemez.
		local other1 = TowerId.new(ax, by)
		local other2 = TowerId.new(bx, ay)
		if TowerId.distanceSquared(other1, other2) <= distance then
			return false
		end
	end
	return true
end

-- `NeighborTable` (bit n = yön n yolla bağlı). İhtiyaç anında hesaplanır, önbelleğe alınır.
-- 0..255 değerinin hepsi geçerli olduğundan "hesaplandı" bilgisi ayrı tutulur.
local neighborCache = buffer.create(WORLD_SIZE * WORLD_SIZE)
local neighborComputed = buffer.create(WORLD_SIZE * WORLD_SIZE)

local function neighborBits(id: TowerId): number
	local x, y = id // U16, id % U16
	-- Kaynakta tablo [y][x] ile maskesiz okunur; dünya dışı id'de panik olurdu.
	assert(x < WORLD_SIZE and y < WORLD_SIZE, "neighborBits: tower id outside world")
	local index = y * WORLD_SIZE + x
	if buffer.readu8(neighborComputed, index) == 0 then
		local bits = 0
		for n = 0, 7 do
			if areNeighbors(id, rawNeighbor(id, n)) then
				bits = bit32.bor(bits, bit32.lshift(1, n))
			end
		end
		buffer.writeu8(neighborCache, index, bits)
		buffer.writeu8(neighborComputed, index, 1)
	end
	return buffer.readu8(neighborCache, index)
end

-- `TowerNeighbor::opposite`
function TowerId.opposite(neighbor: TowerNeighbor): TowerNeighbor
	return bit32.band(neighbor + 4, 7)
end

-- `TryFrom<I16Vec2> for TowerNeighbor`: (dx, dy) → yön ya da nil.
local function neighborFromDelta(dx: number, dy: number): TowerNeighbor?
	for n = 0, 7 do
		if DX[n + 1] == dx and DY[n + 1] == dy then
			return n
		end
	end
	return nil
end

-- `TowerId::neighbor_to`
function TowerId.neighborTo(a: TowerId, b: TowerId): TowerNeighbor?
	local n = neighborFromDelta(b // U16 - a // U16, b % U16 - a % U16)
	if n == nil then
		return nil
	end
	if bit32.band(neighborBits(a), bit32.lshift(1, n)) == 0 then
		return nil
	end
	return n
end

-- `TowerId::is_neighbor`: yolla bağlı mı.
function TowerId.isNeighbor(a: TowerId, b: TowerId): boolean
	return TowerId.neighborTo(a, b) ~= nil
end

-- `TowerId::neighbor_unchecked`
function TowerId.neighborUnchecked(id: TowerId, neighbor: TowerNeighbor): TowerId
	return rawNeighbor(id, neighbor)
end

-- `TowerId::neighbor`
function TowerId.neighbor(id: TowerId, neighbor: TowerNeighbor): TowerId?
	local other = rawNeighbor(id, neighbor)
	if TowerId.isNeighbor(id, other) then
		return other
	end
	return nil
end

export type NeighborEntry = { neighbor: TowerNeighbor, id: TowerId }

-- `TowerId::neighbors_enumerated`: yön sırasıyla (N, NE, E, SE, S, SW, W, NW).
function TowerId.neighborsEnumerated(id: TowerId): { NeighborEntry }
	local bits = neighborBits(id)
	local list = {}
	for n = 0, 7 do
		if bit32.band(bits, bit32.lshift(1, n)) ~= 0 then
			table.insert(list, { neighbor = n, id = rawNeighbor(id, n) })
		end
	end
	return list
end

-- `TowerId::neighbors`: yön sırasıyla.
function TowerId.neighbors(id: TowerId): { TowerId }
	local bits = neighborBits(id)
	local list = {}
	for n = 0, 7 do
		if bit32.band(bits, bit32.lshift(1, n)) ~= 0 then
			table.insert(list, rawNeighbor(id, n))
		end
	end
	return list
end

-- `TowerId::iter_radius`: dünya koordinatında `radius` içindeki id'ler.
-- Kaynak f32 kullanır; konumlar küçük tamsayı olduğu için double ile sonuç aynıdır.
-- Sıra: `TowerRectangle::into_iter` (önce y, içinde x), tower/rectangle.rs ile doğrulandı.
function TowerId.iterRadius(id: TowerId, radius: number): { TowerId }
	local cx, cy = TowerId.integerPosition(id)
	local radiusSquared = radius * radius
	local r = (radius + CONVERSION - 1) // CONVERSION
	local x, y = id // U16, id % U16
	local minX, minY = math.max(x - r, 0), math.max(y - r, 0)
	local maxX, maxY = math.min(x + r, U16 - 1), math.min(y + r, U16 - 1)
	local list = {}
	for ty = minY, maxY do
		for tx = minX, maxX do
			local other = TowerId.new(tx, ty)
			local px, py = TowerId.integerPosition(other)
			local dx, dy = px - cx, py - cy
			if dx * dx + dy * dy <= radiusSquared then
				table.insert(list, other)
			end
		end
	end
	return list
end

-- `ChunkId::from(TowerId)`: (cx, cy)
function TowerId.chunk(id: TowerId): (number, number)
	return (id // U16) // TowerId.CHUNK_SIZE, (id % U16) // TowerId.CHUNK_SIZE
end

-- `Chunk::tick` içindeki tick kaydırması: `u16::from_le_bytes([chunk_id.x, chunk_id.y])`.
function TowerId.chunkTickOffset(id: TowerId): number
	local cx, cy = TowerId.chunk(id)
	return cx + cy * 256
end

-- `World::CENTER`
TowerId.CENTER = TowerId.new(WORLD_SIZE // 2, WORLD_SIZE // 2)

-- `ConnectivityTable` (connectivity.rs): merkezden BFS ile her kuleye "merkeze doğru" yön.
-- Değer: yön + 1 (0 = yok). İlk kullanımda bir kez hesaplanır.
local connectivity: buffer? = nil

local function buildConnectivity(): buffer
	local table_ = buffer.create(WORLD_SIZE * WORLD_SIZE)
	local function index(id: TowerId): number
		return (id % U16) * WORLD_SIZE + id // U16
	end

	local center = TowerId.CENTER
	local first = TowerId.neighbors(center)[1]
	local centerNeighbor = TowerId.neighborTo(center, first)
	assert(centerNeighbor ~= nil, "center has no neighbor")
	buffer.writeu8(table_, index(center), centerNeighbor + 1)

	-- FIFO kuyruk (VecDeque)
	local queue: { [number]: TowerId } = { center }
	local head, tail = 1, 1
	while head <= tail do
		local parent = queue[head]
		queue[head] = nil
		head += 1
		for _, entry in TowerId.neighborsEnumerated(parent) do
			local i = index(entry.id)
			if buffer.readu8(table_, i) == 0 then
				buffer.writeu8(table_, i, TowerId.opposite(entry.neighbor) + 1)
				tail += 1
				queue[tail] = entry.id
			end
		end
	end
	return table_
end

-- Tabloyu şimdi kur (512×512 BFS, ~0,5 sn). Sunucu açılışında çağrılır ki ilk oyun adımında
-- gecikme olmasın.
function TowerId.prepareConnectivity()
	if connectivity == nil then
		connectivity = buildConnectivity()
	end
end

-- `TowerId::connectivity`: merkeze doğru yön, bağlantısızsa nil.
function TowerId.connectivity(id: TowerId): TowerNeighbor?
	if connectivity == nil then
		connectivity = buildConnectivity()
	end
	local value = buffer.readu8(connectivity :: buffer, (id % U16) * WORLD_SIZE + id // U16)
	if value == 0 then
		return nil
	end
	return value - 1
end

-- `TowerId::connectivity_id`
function TowerId.connectivityId(id: TowerId): TowerId?
	local direction = TowerId.connectivity(id)
	if direction == nil then
		return nil
	end
	return rawNeighbor(id, direction)
end

return table.freeze(TowerId)
