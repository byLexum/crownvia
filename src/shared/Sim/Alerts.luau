--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/alerts.rs, server/src/service.rs (tick)

-- Kiomet'te `common/src/alerts.rs` `Alerts` + `AlertFlag` ve `TowerService::tick` içindeki
-- saniyelik hesap → bizde bu modül. Saf Luau.

local Tower = require("./Tower")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local Unit = require("./Unit")
local Units = require("./Units")
local World = require("./World")

type TowerId = TowerId.TowerId

-- `struct Alerts`. `flags`: `AlertFlag` bitleri (u8).
export type Alerts = {
	-- Kralın yaklaşık konumu (biliniyorsa).
	rulerPosition: TowerId?,
	-- Kapasitesini aşan (taşan) birimli kule.
	overflowing: TowerId?,
	-- Kapasitesi dolmuş, üretimi duran kule.
	full: TowerId?,
	-- Sahipsiz (zombi) birlik saldırısı altındaki kule.
	zombies: TowerId?,
	flags: number,
}

local Alerts = {}

-- `enum AlertFlag` (flagset bit sırası)
Alerts.RulerNotSafe = 1
Alerts.RulerUnderAttack = 2
Alerts.DeployedAnyForce = 4
Alerts.UpgradedAnyTower = 8
Alerts.SetAnySupplyLine = 16
Alerts.UnsetAnySupplyLine = 32

-- `Alerts::default`
function Alerts.new(): Alerts
	return { rulerPosition = nil, overflowing = nil, full = nil, zombies = nil, flags = 0 }
end

function Alerts.has(alerts: Alerts, flag: number): boolean
	return bit32.band(alerts.flags, flag) ~= 0
end

function Alerts.set(alerts: Alerts, flag: number)
	alerts.flags = bit32.bor(alerts.flags, flag)
end

-- `Alerts::reset_ephemeral`: yeniden hesaplanacak alanlar temizlenir; kalıcı bayraklar
-- (DeployedAnyForce vb., öğretici için) kalır.
function Alerts.resetEphemeral(alerts: Alerts)
	alerts.rulerPosition = nil
	alerts.full = nil
	alerts.overflowing = nil
	alerts.zombies = nil
	alerts.flags = bit32.band(
		alerts.flags,
		bit32.bnot(bit32.bor(Alerts.RulerUnderAttack, Alerts.RulerNotSafe))
	)
end

-- `TowerService::tick` saniyelik uyarı hesabı (bir kule için). `flags` döner.
-- `overflowing`/`full`/`zombies` son bulunan kuleyi tutar. Kaynakta kule sırası `FxHashSet`
-- sırasıdır; bizde çağıran id sırasıyla verir. Yalnız hangi kulenin gösterileceğini etkiler.
function Alerts.updateTower(
	alerts: Alerts,
	flags: number,
	world: World.World,
	playerId: number,
	towerId: TowerId,
	tower: Tower.Tower
): number
	if Units.hasRuler(tower.units) then
		alerts.rulerPosition = towerId
		local shielded = Units.available(tower.units, Unit.Shield)
			>= Unit.damageToFinite(TowerType.maxRangedDamage(tower.towerType))
		local surrounded = true
		for _, neighborId in TowerId.neighbors(towerId) do
			local neighbor = World.get(world, neighborId)
			if neighbor ~= nil and neighbor.playerId ~= playerId then
				surrounded = false
				break
			end
		end
		local allInboundOwn = true
		local anyInboundOther = false
		for _, force in tower.inboundForces do
			if force.playerId ~= playerId then
				allInboundOwn = false
				anyInboundOther = true
			end
		end
		if (shielded or surrounded) and allInboundOwn then
			flags = bit32.band(flags, bit32.bnot(Alerts.RulerNotSafe))
		elseif anyInboundOther then
			flags = bit32.bor(flags, Alerts.RulerUnderAttack)
		end
	elseif Tower.active(tower) then
		for _, unit in Unit.all() do
			if
				not Unit.isMobile(unit, tower.towerType) or not Units.contains(tower.units, unit)
			then
				continue
			end
			local generates = Tower.unitGeneration(tower, unit) ~= nil
			if generates and tower.supplyLine ~= nil then
				-- Sorun kendiliğinden geçecek.
				continue
			end
			local available = Units.available(tower.units, unit)
			local capacity = Units.capacity(tower.units, unit, tower.towerType)
			if available > capacity then
				alerts.overflowing = towerId
			elseif available == capacity and generates then
				alerts.full = towerId
			end
		end
	end

	for _, force in tower.inboundForces do
		if force.playerId == nil then
			alerts.zombies = towerId
			break
		end
	end
	return flags
end

function Alerts.equals(a: Alerts, b: Alerts): boolean
	return a.rulerPosition == b.rulerPosition
		and a.overflowing == b.overflowing
		and a.full == b.full
		and a.zombies == b.zombies
		and a.flags == b.flags
end

function Alerts.clone(alerts: Alerts): Alerts
	return table.clone(alerts)
end

return table.freeze(Alerts)
