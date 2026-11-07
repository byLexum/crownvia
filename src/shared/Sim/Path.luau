--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/force.rs

-- Kiomet'te `common/src/force.rs` içindeki `struct Path` → bizde bu modül.
-- Kaynak listeyi ters sırada tutar (önden hızlı çıkarmak için). Burada düz sırada tutulur;
-- yollar en fazla 16 kule olduğundan `table.remove(ids, 1)` ucuzdur. Davranış aynı.

local TowerId = require("./TowerId")

type TowerId = TowerId.TowerId

export type Path = {
	-- Kaynak (ilk) → hedef (son). Değişmez: en az 2 eleman (kaynakta `assert!`).
	ids: { TowerId },
}

local Path = {}

-- `World::MAX_PATH_ROADS` (world.rs)
Path.MAX_PATH_ROADS = 16

-- `Path::new`: en az 2 kule.
function Path.new(ids: { TowerId }): Path
	assert(#ids >= 2, "Path.new: path must have at least 2 towers")
	return { ids = table.clone(ids) }
end

function Path.clone(path: Path): Path
	return { ids = table.clone(path.ids) }
end

-- `PartialEq`
function Path.equals(a: Path, b: Path): boolean
	if #a.ids ~= #b.ids then
		return false
	end
	for i, id in a.ids do
		if b.ids[i] ~= id then
			return false
		end
	end
	return true
end

-- `Path::validate`. `contains(id)`: kule üretilmiş mi (`towers.contains`).
-- `maxEdgeDistance` nil değilse menzilli yol: tam 2 kule ve kenar ≤ menzil.
function Path.validate(
	path: Path,
	contains: (TowerId) -> boolean,
	sourceTowerId: TowerId,
	maxEdgeDistance: number?
): (boolean, string?)
	local ids = path.ids
	if #ids < 2 then
		return false, "path too short"
	end
	if
		(maxEdgeDistance ~= nil and #ids ~= 2)
		or (maxEdgeDistance == nil and #ids > Path.MAX_PATH_ROADS)
	then
		return false, "path too long"
	end
	if ids[1] ~= sourceTowerId then
		return false, "source mismatch"
	end

	local maxDistanceSquared = if maxEdgeDistance ~= nil then (maxEdgeDistance + 1) ^ 2 - 1 else nil

	local prev = sourceTowerId
	for i = 2, #ids do
		local nextId = ids[i]
		if nextId == prev then
			return false, "duplicate tower in path"
		end
		if not TowerId.inWorld(nextId) then
			return false, "outside world"
		end
		if maxDistanceSquared ~= nil then
			if TowerId.distanceSquared(prev, nextId) > maxDistanceSquared then
				return false, "edge too long"
			end
		elseif not TowerId.isNeighbor(prev, nextId) then
			return false, "not neighbor"
		end
		if not contains(nextId) then
			return false, "not generated"
		end
		prev = nextId
	end
	return true, nil
end

-- `Path::coming_from`
function Path.comingFrom(path: Path): TowerId
	return path.ids[1]
end

-- `Path::going_to`
function Path.goingTo(path: Path): TowerId
	return path.ids[2]
end

-- `Path::source`
function Path.source(path: Path): TowerId
	return path.ids[1]
end

-- `Path::destination`
function Path.destination(path: Path): TowerId
	return path.ids[#path.ids]
end

-- `Path::pop`: ilk kuleye varıldı.
function Path.pop(path: Path)
	table.remove(path.ids, 1)
end

-- `Path::is_empty`: segment kalmadı (< 2 kule).
function Path.isEmpty(path: Path): boolean
	return #path.ids < 2
end

return table.freeze(Path)
