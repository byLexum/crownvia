--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/tower.rs, common/src/chunk/event.rs

-- Kiomet'te `common/src/tower.rs` içindeki `struct Tower` ve `impl Tower` → bizde bu modül.
-- `chunk/event.rs` içindeki `Tower::deploy_force` / `send_force` da burada; kaynakta chunk
-- olayları döndürürler, burada eklenecek birlikleri (giden kopya + gelen) döndürürler.

local Force = require("./Force")
local Path = require("./Path")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local Unit = require("./Unit")
local Units = require("./Units")

type Force = Force.Force
type Path = Path.Path
type TowerId = TowerId.TowerId
type Units = Units.Units

export type Tower = {
	playerId: number?,
	units: Units,
	towerType: number,
	-- Kullanılabilir olana kadar tick (u8, NonZeroU8). nil → aktif.
	delay: number?,
	-- Bu kuleye gelmekte olan birlikler.
	inboundForces: { Force },
	-- Karşı kulenin gelen birliklerinin aynası (yolda çarpışma için).
	outboundForces: { Force },
	-- Üretemediğinde ya da taştığında birimlerini göndereceği yol.
	supplyLine: Path?,
}

-- `send_force` sonucu: `dst` kulesine eklenecek birlik.
export type ForceEvent = {
	kind: "outbound" | "inbound",
	towerId: TowerId,
	force: Force,
}

local Tower = {}

-- `Tower::RULER_SHIELD_BOOST`
Tower.RULER_SHIELD_BOOST = Units.RULER_SHIELD_BOOST

-- `Tower::with_type`
function Tower.withType(towerType: number): Tower
	return {
		playerId = nil,
		units = Units.new(),
		towerType = towerType,
		delay = nil,
		inboundForces = {},
		outboundForces = {},
		supplyLine = nil,
	}
end

-- `Tower::new`: haritadaki tipiyle.
function Tower.new(towerId: TowerId): Tower
	return Tower.withType(TowerId.towerType(towerId))
end

-- `Tower::active`: yükseltmede olmayan kule üretir, görür, ön koşullara sayılır.
function Tower.active(tower: Tower): boolean
	return tower.delay == nil
end

-- `Tower::can_destroy`
function Tower.canDestroy(tower: Tower): boolean
	return #tower.inboundForces == 0 and tower.playerId == nil
end

-- `Tower::iter_rulers`: kralı bu kulede olan ya da bu kuleye gelen oyuncular.
function Tower.iterRulers(tower: Tower): { number }
	local list = {}
	if tower.playerId ~= nil and Units.hasRuler(tower.units) then
		table.insert(list, tower.playerId)
	end
	for _, force in tower.inboundForces do
		if Units.hasRuler(force.units) then
			table.insert(list, force.playerId :: number)
		end
	end
	return list
end

-- `Tower::force_units`: birliğe katılabilecek (hareketli) birimler.
function Tower.forceUnits(tower: Tower): Units
	local result = Units.new()
	for _, entry in Units.iter(tower.units) do
		if Unit.isMobile(entry.unit, tower.towerType) then
			Units.add(result, entry.unit, entry.count)
		end
	end
	return result
end

-- `Tower::take_force_units`
function Tower.takeForceUnits(tower: Tower): Units
	local result = Tower.forceUnits(tower)
	for _, entry in Units.iter(result) do
		Units.subtract(tower.units, entry.unit, entry.count)
	end
	return result
end

-- `Tower::diminish_units_if_dead_or_overflow`: azalan hareketli birim sayısını döner.
function Tower.diminishUnitsIfDeadOrOverflow(tower: Tower): number
	local diminished = 0
	for unit = 0, Unit.COUNT - 1 do
		if
			tower.playerId == nil
			or Units.available(tower.units, unit)
				> Units.capacity(tower.units, unit, tower.towerType)
		then
			local subtracted = Units.subtract(tower.units, unit, 1)
			if Unit.isMobile(unit, tower.towerType) then
				diminished += subtracted
			end
		end
	end
	return diminished
end

-- `Tower::unit_generation`: kral varken Shield dışında üretim yok.
function Tower.unitGeneration(tower: Tower, unit: number): number?
	if unit ~= Unit.Shield and Units.hasRuler(tower.units) then
		return nil
	end
	return TowerType.unitGeneration(tower.towerType, unit)
end

-- `Tower::generates_mobile_units` (kral durumunu hesaba katar)
function Tower.generatesMobileUnits(tower: Tower): boolean
	for unit = 0, Unit.COUNT - 1 do
		if Unit.isMobile(unit, tower.towerType) and Tower.unitGeneration(tower, unit) ~= nil then
			return true
		end
	end
	return false
end

-- `Tower::reconcile_units`
function Tower.reconcileUnits(tower: Tower)
	Units.reconcile(tower.units, tower.towerType, tower.playerId ~= nil)
end

-- `Tower::set_player_id` / `set_player_id_inner`. Sahiplik her zaman bununla değişir.
-- Kaynaktaki debug_assert'ler (Ruler/Shield olmamalı) burada da hata olarak kontrol edilir.
function Tower.setPlayerId(tower: Tower, playerId: number?)
	local current = tower.playerId
	assert(current ~= playerId, "setPlayerId: unchanged player id")
	assert(not Units.contains(tower.units, Unit.Ruler), "setPlayerId: tower has ruler")
	assert(not Units.contains(tower.units, Unit.Shield), "setPlayerId: tower has shield")
	if current == nil then
		assert(tower.supplyLine == nil, "setPlayerId: unowned tower has supply line")
	else
		tower.supplyLine = nil
	end
	tower.playerId = playerId
end

-- `Tower::send_force`: giden (yarıda kesilmiş kopya) + gelen birlik olayları.
function Tower.sendForce(_tower: Tower, force: Force): { ForceEvent }
	return {
		-- `ChunkEvent::add_outbound_force`: bant genişliği için yarıda kesilmiş kopya.
		{ kind = "outbound", towerId = Force.currentSource(force), force = Force.halted(force) },
		{ kind = "inbound", towerId = Force.currentDestination(force), force = force },
	}
end

-- `Tower::deploy_force`: kuledeki hareketli birimleri `path` boyunca gönderir.
function Tower.deployForce(tower: Tower, path: Path): { ForceEvent }
	local units = Tower.takeForceUnits(tower)
	local playerId = tower.playerId
	assert(playerId ~= nil, "deployForce: tower has no player")
	return Tower.sendForce(tower, Force.new(playerId, units, path))
end

return table.freeze(Tower)
