--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/world.rs (astar, find_best_path, find_best_incomplete_path)
-- Derived from pathfinding 3.0.14 (c) Samuel Tardieu — MIT/Apache-2.0. Source: src/directed/astar.rs (astar, SmallestCostHolder, reverse_path)
-- Derived from Rust std (c) The Rust Project Developers — MIT/Apache-2.0. Source: alloc/collections/binary_heap (push, pop, sift_up, sift_down_to_bottom)

-- Kiomet'te `World::astar` → bizde `Pathfinding.astar`. Eşit maliyetli yollarda kaynakla aynı yolu
-- seçmek için A* (`pathfinding` crate) ve öncelik kuyruğu (`std::collections::BinaryHeap`)
-- birebir taklit edilir: aynı karşılaştırma, aynı ekleme sırası (IndexMap), aynı yığın algoritması.
-- Std'nin yığın algoritması derleyici sürümüne bağlıdır; Kiomet'in kullandığı nightly'deki hali
-- ile birebir aynı olduğu doğrulanmadı (varsayım, uzun süredir değişmeyen algoritma).
--
-- Dünyaya erişim `View` arayüzü ile: sunucu tam dünyayı, istemci bildiği kuleleri verir.

local TowerId = require("./TowerId")
local Units = require("./Units")
local World = require("./World")

type TowerId = TowerId.TowerId
type World = World.World

export type View = {
	-- Kule üretilmiş/biliniyor mu (`chunk.get(id).is_some()`)
	exists: (TowerId) -> boolean,
	owner: (TowerId) -> number?,
	-- Kulede birim var mı (`!tower.units.is_empty()`)
	hasUnits: (TowerId) -> boolean,
	haveAlliance: (number, number) -> boolean,
}

local Pathfinding = {}

-- Sabit nokta ölçeği: mesafe² × 2^16, karekökü × 2^8.
local D2_SCALE = 65536
local D_SCALE = 256
local U32_MAX = 4294967295
local USIZE_MAX = -1 -- `usize::MAX` ebeveyn işareti

-- `SmallestCostHolder`
type Holder = { estimated: number, cost: number, index: number }

-- `impl Ord for SmallestCostHolder`: tahmini maliyeti küçük olan büyüktür; eşitse maliyeti büyük olan.
local function cmp(a: Holder, b: Holder): number
	if b.estimated < a.estimated then
		return -1
	elseif b.estimated > a.estimated then
		return 1
	end
	if a.cost < b.cost then
		return -1
	elseif a.cost > b.cost then
		return 1
	end
	return 0
end

-- `std::collections::BinaryHeap` (max-heap), 0 tabanlı indeks `data[i + 1]`.
type Heap = { data: { Holder }, len: number }

local function siftUp(heap: Heap, start: number, pos: number): number
	local data = heap.data
	local element = data[pos + 1]
	while pos > start do
		local parent = (pos - 1) // 2
		if cmp(element, data[parent + 1]) <= 0 then
			break
		end
		data[pos + 1] = data[parent + 1]
		pos = parent
	end
	data[pos + 1] = element
	return pos
end

local function siftDownToBottom(heap: Heap, pos: number)
	local data = heap.data
	local finish = heap.len
	local start = pos
	local element = data[pos + 1]
	local child = 2 * pos + 1
	-- `while child <= end.saturating_sub(2)`
	while child <= math.max(finish - 2, 0) do
		if cmp(data[child + 1], data[child + 2]) <= 0 then
			child += 1
		end
		data[pos + 1] = data[child + 1]
		pos = child
		child = 2 * pos + 1
	end
	if child == finish - 1 then
		data[pos + 1] = data[child + 1]
		pos = child
	end
	data[pos + 1] = element
	siftUp(heap, start, pos)
end

local function heapPush(heap: Heap, item: Holder)
	heap.len += 1
	heap.data[heap.len] = item
	siftUp(heap, 0, heap.len - 1)
end

local function heapPop(heap: Heap): Holder?
	if heap.len == 0 then
		return nil
	end
	local last = heap.data[heap.len]
	heap.data[heap.len] = nil :: any
	heap.len -= 1
	if heap.len > 0 then
		local item = heap.data[1]
		heap.data[1] = last
		siftDownToBottom(heap, 0)
		return item
	end
	return last
end

Pathfinding._heapPush = heapPush
Pathfinding._heapPop = heapPop
Pathfinding._newHeap = function(): Heap
	return { data = {}, len = 0 }
end

export type Successor = { node: TowerId, cost: number }

-- `pathfinding::directed::astar::astar`
local function crateAstar(
	start: TowerId,
	successors: (TowerId) -> { Successor },
	heuristic: (TowerId) -> number,
	success: (TowerId) -> boolean
): { TowerId }?
	local heap: Heap = { data = {}, len = 0 }
	heapPush(heap, { estimated = 0, cost = 0, index = 0 })

	-- `FxIndexMap<N, (usize, C)>`: ekleme sırası = indeks.
	local nodes: { TowerId } = { start }
	local parents: { number } = { USIZE_MAX }
	local costs: { number } = { 0 }
	local indexOf: { [TowerId]: number } = { [start] = 0 }

	while true do
		local holder = heapPop(heap)
		if holder == nil then
			return nil
		end
		local index = holder.index
		local node = nodes[index + 1]
		if success(node) then
			-- `reverse_path`
			local reversed = {}
			local i = index
			while i ~= USIZE_MAX do
				table.insert(reversed, nodes[i + 1])
				i = parents[i + 1]
			end
			local path = table.create(#reversed)
			for j = #reversed, 1, -1 do
				table.insert(path, reversed[j])
			end
			return path
		end
		-- Aynı düğüm daha iyi yolla tekrar eklenmiş olabilir; eskisini atla.
		if holder.cost > costs[index + 1] then
			continue
		end
		for _, successor in successors(node) do
			local newCost = holder.cost + successor.cost
			local existing = indexOf[successor.node]
			local h, n
			if existing == nil then
				h = heuristic(successor.node)
				n = #nodes
				table.insert(nodes, successor.node)
				table.insert(parents, index)
				table.insert(costs, newCost)
				indexOf[successor.node] = n
			elseif costs[existing + 1] > newCost then
				h = heuristic(successor.node)
				n = existing
				parents[existing + 1] = index
				costs[existing + 1] = newCost
			else
				continue
			end
			heapPush(heap, { estimated = newCost + h, cost = newCost, index = n })
		end
	end
end

-- `World::astar`: yol ya da (bulunamazsa) hedefe en yakın ulaşılabilir kule.
function Pathfinding.astar(
	view: View,
	src: TowerId,
	dst: TowerId,
	playerId: number,
	filter: (TowerId) -> boolean
): ({ TowerId }?, TowerId)
	local dstPlayerId = if view.exists(dst) then view.owner(dst) else nil
	local shortestNode, shortestH = src, U32_MAX

	-- Makul sürede yol bulunamazsa her kuleyi gezme (u16).
	local emergencyStop = 128 + math.max(TowerId.distance(src, dst), 2048)

	local function successors(pos: TowerId): { Successor }
		local list = {}
		for _, id in TowerId.neighbors(pos) do
			if view.exists(id) then
				local owner = view.owner(id)
				local passesThroughAlliance = owner ~= nil
					and owner ~= dstPlayerId
					and view.haveAlliance(playerId, owner)
				if not passesThroughAlliance and filter(id) then
					local d2 = TowerId.distanceSquared(pos, id)
					table.insert(list, { node = id, cost = TowerId.integerSqrt(d2 * D2_SCALE) })
				end
			end
		end
		return list
	end

	local function heuristic(pos: TowerId): number
		local h = TowerId.integerSqrt(TowerId.distanceSquared(pos, dst) * D2_SCALE)
		local owner = view.owner(pos)
		if owner == playerId then
			-- Yeni kule almaya öncelik.
			h += 2 * D_SCALE
		elseif owner ~= nil or view.hasUnits(pos) then
			-- Düşman/zombi içinden geçmeyi geri plana at.
			h += 32 * D_SCALE
		end
		if h < shortestH then
			shortestNode, shortestH = pos, h
		end
		return h
	end

	local function success(pos: TowerId): boolean
		emergencyStop -= 1
		return pos == dst or emergencyStop == 0
	end

	local path = crateAstar(src, successors, heuristic, success)
	if path ~= nil and emergencyStop > 0 then
		return path, shortestNode
	end
	return nil, shortestNode
end

-- `World::find_best_path`
function Pathfinding.findBestPath(
	view: View,
	src: TowerId,
	dst: TowerId,
	maxEdgeDistance: number?,
	playerId: number,
	filter: (TowerId) -> boolean
): { TowerId }?
	if maxEdgeDistance ~= nil then
		if TowerId.distance(src, dst) <= maxEdgeDistance and filter(dst) then
			return { src, dst }
		end
		return nil
	end
	local path = Pathfinding.astar(view, src, dst, playerId, filter)
	if path ~= nil and #path >= 2 then
		return path
	end
	return nil
end

-- `World::find_best_incomplete_path`: bulunamazsa ulaşılabilen en yakın kuleye yol.
function Pathfinding.findBestIncompletePath(
	view: View,
	src: TowerId,
	dst: TowerId,
	maxEdgeDistance: number?,
	playerId: number,
	filter: (TowerId) -> boolean
): { TowerId }
	if maxEdgeDistance ~= nil then
		if TowerId.distance(src, dst) <= maxEdgeDistance and filter(dst) then
			return { src, dst }
		end
		return { src }
	end
	local path, reachable = Pathfinding.astar(view, src, dst, playerId, filter)
	if path ~= nil then
		return path
	end
	return Pathfinding.astar(view, src, reachable, playerId, filter) or {}
end

-- Sunucu: tam dünya görünümü.
function Pathfinding.worldView(world: World): View
	return {
		exists = function(id)
			return World.contains(world, id)
		end,
		owner = function(id)
			local tower = World.get(world, id)
			return if tower then tower.playerId else nil
		end,
		hasUnits = function(id)
			local tower = World.get(world, id)
			return tower ~= nil and not Units.isEmpty(tower.units)
		end,
		haveAlliance = function(a, b)
			return World.haveAlliance(world, a, b)
		end,
	}
end

return table.freeze(Pathfinding)
