--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/force.rs

-- Kiomet'te `common/src/force.rs` içindeki `struct Force` ve `impl Force` → bizde bu modül.
--
-- Tek ek alan: `id`. Kaynakta yok; yalnız istemcinin aynı birliği tick'ler arasında tanıması için
-- (replikasyon). Kurallara katılmaz; kopyalar (`clone`, `halted`) aynı id'yi taşır.

local Path = require("./Path")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local TowerTypeId = require("./TowerTypeId")
local Unit = require("./Unit")
local Units = require("./Units")

type Path = Path.Path
type TowerId = TowerId.TowerId
type Units = Units.Units

export type Force = {
	id: number,
	-- Değişmez: en az iki kule.
	path: Path,
	-- u8
	pathProgress: number,
	-- u8, başlangıç 150
	fuel: number,
	-- nil → kule alamaz, sadece öldürür (kaynakta küçülen dünya için).
	playerId: number?,
	units: Units,
}

local Force = {}

-- `Force::new_inner` içindeki başlangıç yakıtı.
Force.INITIAL_FUEL = 150

local Speed = Unit.Speed
local U8_MAX = 255

local nextId = 0

-- `Force::new_inner`
function Force.newInner(playerId: number?, units: Units, path: Path): Force
	nextId += 1
	return {
		id = nextId,
		path = path,
		pathProgress = 0,
		fuel = Force.INITIAL_FUEL,
		playerId = playerId,
		units = units,
	}
end

-- `Force::new`
function Force.new(playerId: number, units: Units, path: Path): Force
	return Force.newInner(playerId, units, path)
end

function Force.clone(force: Force): Force
	return {
		id = force.id,
		path = Path.clone(force.path),
		pathProgress = force.pathProgress,
		fuel = force.fuel,
		playerId = force.playerId,
		units = Units.clone(force.units),
	}
end

-- `Force::current_source`
function Force.currentSource(force: Force): TowerId
	return Path.comingFrom(force.path)
end

-- `Force::current_destination`
function Force.currentDestination(force: Force): TowerId
	return Path.goingTo(force.path)
end

-- `Force::halt`: mevcut hedefe varır ama devam etmez.
function Force.halt(force: Force)
	force.path = Path.new({ force.path.ids[1], force.path.ids[2] })
end

-- `Force::halted`: `force.clone().halt()` eşdeğeri.
function Force.halted(force: Force): Force
	return {
		id = force.id,
		path = Path.new({ force.path.ids[1], force.path.ids[2] }),
		pathProgress = force.pathProgress,
		fuel = force.fuel,
		playerId = force.playerId,
		units = Units.clone(force.units),
	}
end

-- `Force::speed`. Chopper'lar taşıyabildikleri kadar yavaş birimi hızlı taşır (chopper başına ağırlık 4).
function Force.speed(force: Force): number
	local units = force.units
	local choppers = Units.available(units, Unit.Chopper)
	if choppers ~= 0 then
		local weight = 0
		for _, entry in Units.iter(units) do
			weight += Unit.weight(entry.unit) * entry.count
		end
		local maxWeight = choppers * 4
		if weight <= maxWeight then
			return Speed.Fast
		end
		-- Hepsini taşıyamıyorsa en yavaşları taşır.
		local slowWeight = 0
		for _, entry in Units.iter(units) do
			if Unit.speed(entry.unit, nil) < Speed.Normal then
				slowWeight += Unit.weight(entry.unit) * entry.count
			end
		end
		if slowWeight <= maxWeight then
			return Speed.Normal
		end
		return Speed.Slow
	end

	local slowest: number? = nil
	for _, entry in Units.iter(units) do
		local speed = Unit.speed(entry.unit, nil)
		if slowest == nil or speed < slowest then
			slowest = speed
		end
	end
	-- Kaynakta boş birlik için debug_assert, release'de Fast ("hide the evidence").
	return slowest or Speed.Fast
end

-- `Force::progress_per_tick`
function Force.progressPerTick(force: Force): number
	local speed = Force.speed(force)
	if speed == Speed.Slow then
		return 1
	elseif speed == Speed.Normal then
		return 2
	elseif speed == Speed.Fast then
		return 3
	end
	return 0
end

-- `Force::progress_required`: mesafe × 180 / 5 / 2 (tamsayı), u8'e kırpılır.
function Force.progressRequired(force: Force): number
	local distance = TowerId.distance(Force.currentSource(force), Force.currentDestination(force))
	local required = ((distance * 180) // TowerId.MAX_ROAD_LENGTH) // 2
	return math.min(required, U8_MAX)
end

-- `Force::raw_tick`: ilerler; varınca yolun ilk kulesini düşürür ve true döner.
function Force.rawTick(force: Force): boolean
	force.pathProgress = math.min(force.pathProgress + Force.progressPerTick(force), U8_MAX)
	if force.pathProgress >= Force.progressRequired(force) then
		Path.pop(force.path)
		return true
	end
	return false
end

-- `Force::tick`: gelen birlik için `raw_tick` (kaynaktaki assert'ler dahil).
function Force.tick(force: Force, inboundTowerId: TowerId): boolean
	assert(Force.currentSource(force) ~= inboundTowerId, "Force.tick: source equals inbound tower")
	local arrived = Force.rawTick(force)
	if arrived then
		assert(Force.currentSource(force) == inboundTowerId, "Force.tick: arrived at wrong tower")
	end
	return arrived
end

-- `Force::try_move_on`: yol devam ediyorsa (ya da ikmal hattına geçtiyse) true.
-- `ally`: kule müttefikse müttefikin id'si. `supplyLine`: kulenin ikmal hattı.
function Force.tryMoveOn(
	force: Force,
	towerType: number,
	towerUnits: Units,
	ally: number?,
	supplyLine: Path?
): boolean
	if Path.isEmpty(force.path) or ally ~= nil then
		if
			supplyLine ~= nil
			and TowerType.rangedDistance(towerType) == nil
			and Units.isMany(force.units)
		then
			force.path = Path.clone(supplyLine)
			if ally ~= nil then
				-- Müttefikin ikmal hattına giren birlik müttefike devredilir.
				force.playerId = ally
			else
				if towerType == TowerTypeId.Projector then
					local maxShield = TowerType.rawUnitCapacity(TowerTypeId.Projector, Unit.Shield)
					local existingShield = Units.available(force.units, Unit.Shield)
					-- `checked_sub`: mevcut fazlaysa aktarım yok.
					if maxShield >= existingShield then
						local transferred =
							Units.subtract(towerUnits, Unit.Shield, maxShield - existingShield)
						Units.add(force.units, Unit.Shield, transferred)
					end
				end
				if Units.contains(force.units, Unit.Chopper) then
					local initialSpeed = Force.speed(force)
					for _, transfer in { Unit.Soldier, Unit.Tank } do
						if Unit.speed(transfer, nil) >= initialSpeed then
							-- Birliği yavaşlatma.
							break
						end
						while true do
							if not Units.contains(towerUnits, transfer) then
								break
							end
							local added = Units.add(force.units, transfer, 1)
							if added == 0 then
								break
							end
							if Force.speed(force) < initialSpeed then
								-- Kapasite aşıldı, geri al.
								Units.subtract(force.units, transfer, 1)
								break
							end
							Units.subtract(towerUnits, transfer, 1)
						end
					end
				end
			end
		else
			return false
		end
	end

	-- Birlik yoluna devam ediyor.
	force.pathProgress = 0
	if Units.isMany(force.units) then
		force.fuel -= 1
	end
	return true
end

-- İstemci çizimi için `Force::interpolated_position` oranı (0..1). Simülasyonda kullanılmaz.
function Force.interpolatedFraction(force: Force, timeSinceTick: number): number
	local tickFraction = timeSinceTick / 0.25
	local fraction = (force.pathProgress + tickFraction * Force.progressPerTick(force))
		/ Force.progressRequired(force)
	return math.min(fraction, 1)
end

return table.freeze(Force)
