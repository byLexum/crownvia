--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/tower.rs, macros/src/lib.rs

-- Kiomet'te `common/src/tower.rs` içindeki `enum TowerType` öznitelikleri ve `impl TowerType`
-- → bizde bu modül. Öznitelikleri koda çeviren `macros/src/lib.rs` (`TowerTypeData` derive)
-- yerine veri tablosu kullanılır.
--
-- Makro birleştirme kuralı (macros/src/lib.rs): önce enum düzeyindeki öznitelikler, sonra
-- kule tipinin kendi öznitelikleri işlenir; aynı anahtar varsa kule tipininki geçerlidir.
-- Enum düzeyi varsayılanlar:
--   #[tower(sensor_radius = 12)]  #[capacity(Ruler = 1)]  #[prerequisite(10)]  #[generate(Shield = 5)]
-- Ayrıca makroda: score_weight yoksa 1, spawnable yoksa false, prerequisite yoksa 0.

local Ticks = require("./Ticks")
local TowerTypeId = require("./TowerTypeId")
local Unit = require("./Unit")

type TowerTypeId = TowerTypeId.TowerTypeId
type Unit = Unit.Unit
type Ticks = Ticks.Ticks

type RawSpec = {
	downgrade: string?,
	delay: number?, -- saniye
	prerequisites: { [string]: number }?,
	capacity: { [string]: number }?,
	generate: { [string]: number }?, -- birim → saniye
	sensorRadius: number?,
	scoreWeight: number?,
	spawnable: boolean?,
}

type Spec = {
	downgrade: TowerTypeId?,
	delay: Ticks,
	prerequisites: { [TowerTypeId]: number },
	capacity: { [Unit]: number },
	generate: { [Unit]: Ticks },
	sensorRadius: number,
	scoreWeight: number,
	spawnable: boolean,
}

-- tower.rs'deki öznitelikler birebir (yorumlu Capitol/Icbm/Laser/Metropolis hariç, onlar kaynakta da kapalı).
local RAW: { [string]: RawSpec } = {
	Airfield = {
		spawnable = true,
		downgrade = "Runway",
		delay = 20,
		prerequisites = { Factory = 2, Radar = 1 },
		capacity = { Fighter = 4, Bomber = 4, Soldier = 4, Tank = 3, Shield = 10 },
		generate = { Bomber = 30 },
	},
	Armory = {
		spawnable = true,
		downgrade = "Barracks",
		delay = 25,
		prerequisites = { Factory = 1, Mine = 1 },
		capacity = { Soldier = 4, Tank = 5, Shield = 15 },
		generate = { Tank = 15 },
	},
	Artillery = {
		downgrade = "Bunker",
		delay = 40,
		prerequisites = { Refinery = 2, Radar = 3 },
		capacity = { Shell = 3, Shield = 20 },
		generate = { Shell = 15 },
	},
	Barracks = {
		spawnable = true,
		capacity = { Soldier = 12, Tank = 2, Shield = 10 },
		generate = { Soldier = 6 },
	},
	Bunker = {
		downgrade = "Mine",
		delay = 30,
		prerequisites = { Headquarters = 1, Ews = 1 },
		capacity = { Soldier = 6, Shield = 40 },
	},
	Centrifuge = {
		downgrade = "Factory",
		delay = 30,
		prerequisites = { Mine = 3 },
		capacity = { Soldier = 4, Tank = 2, Shield = 15 },
	},
	City = {
		scoreWeight = 5,
		downgrade = "Town",
		delay = 30,
		prerequisites = { Quarry = 2, Reactor = 1, Town = 3 },
		capacity = { Fighter = 2, Soldier = 6, Tank = 2, Shield = 15 },
	},
	Cliff = {
		capacity = { Soldier = 4, Tank = 2, Shield = 30 },
	},
	Ews = {
		sensorRadius = 20,
		downgrade = "Radar",
		delay = 30,
		prerequisites = { Generator = 2 },
		capacity = { Soldier = 4, Tank = 2, Shield = 15 },
	},
	Factory = {
		scoreWeight = 2,
		capacity = { Soldier = 4, Tank = 2, Shield = 10 },
	},
	Generator = {
		capacity = { Soldier = 4, Tank = 2, Shield = 10 },
	},
	Headquarters = {
		downgrade = "Village",
		delay = 20,
		prerequisites = { Radar = 1 },
		capacity = { Soldier = 8, Tank = 2, Shield = 40 },
	},
	Helipad = {
		spawnable = true,
		downgrade = "Airfield",
		delay = 20,
		prerequisites = { Armory = 2, Factory = 3 },
		capacity = { Chopper = 3, Soldier = 4, Tank = 2, Shield = 15 },
		generate = { Chopper = 30 },
	},
	Launcher = {
		downgrade = "Rocket",
		delay = 30,
		prerequisites = { Airfield = 2 },
		capacity = { Emp = 1, Shield = 15 },
		generate = { Emp = 80 },
	},
	Mine = {
		scoreWeight = 2,
		capacity = { Soldier = 4, Tank = 2, Shield = 15 },
	},
	Projector = {
		downgrade = "Centrifuge",
		delay = 20,
		prerequisites = { Rampart = 2, Reactor = 2 },
		capacity = { Soldier = 4, Tank = 2, Shield = 10 },
		generate = { Shield = 3 },
	},
	Quarry = {
		scoreWeight = 2,
		downgrade = "Cliff",
		delay = 20,
		prerequisites = { Village = 1 },
		capacity = { Soldier = 6, Tank = 2, Shield = 10 },
	},
	Radar = {
		sensorRadius = 16,
		capacity = { Soldier = 4, Tank = 2, Shield = 10 },
	},
	Rampart = {
		downgrade = "Cliff",
		delay = 20,
		prerequisites = { Barracks = 2 },
		capacity = { Soldier = 8, Shield = 45 },
		generate = { Shield = 3 },
	},
	Reactor = {
		downgrade = "Generator",
		delay = 40,
		prerequisites = { Centrifuge = 1 },
		capacity = { Soldier = 4, Tank = 2, Shield = 10 },
	},
	Refinery = {
		scoreWeight = 3,
		downgrade = "Factory",
		delay = 20,
		prerequisites = { Generator = 3, Cliff = 1 },
		capacity = { Soldier = 4, Tank = 2, Shield = 5 },
	},
	Rocket = {
		downgrade = "Radar",
		delay = 20,
		prerequisites = { Refinery = 1 },
		capacity = { Soldier = 4, Tank = 2, Shield = 15 },
	},
	Runway = {
		spawnable = true,
		capacity = { Fighter = 4, Soldier = 4, Tank = 2, Shield = 5 },
		generate = { Fighter = 30 },
	},
	Satellite = {
		sensorRadius = 30,
		downgrade = "Ews",
		delay = 40,
		prerequisites = { Rocket = 2, Generator = 5 },
		capacity = { Soldier = 4, Tank = 2, Shield = 15 },
	},
	Silo = {
		downgrade = "Quarry",
		delay = 40,
		prerequisites = { Centrifuge = 2 },
		capacity = { Nuke = 1, Soldier = 4, Tank = 1, Shield = 20 },
		generate = { Nuke = 120 },
	},
	Town = {
		scoreWeight = 2,
		downgrade = "Village",
		delay = 20,
		prerequisites = { Generator = 1, Village = 3 },
		capacity = { Fighter = 1, Soldier = 4, Tank = 1, Shield = 10 },
	},
	Village = {
		capacity = { Soldier = 4, Shield = 5 },
	},
}

-- Enum düzeyi varsayılanlar (tower.rs, `pub enum TowerType` üstündeki öznitelikler).
local DEFAULT_SENSOR_RADIUS = 12
local DEFAULT_DELAY_SECS = 10
local DEFAULT_CAPACITY: { [string]: number } = { Ruler = 1 }
local DEFAULT_GENERATE: { [string]: number } = { Shield = 5 }

local function unitId(name: string): Unit
	local id = (Unit :: any)[name]
	assert(type(id) == "number", "unknown unit " .. name)
	return id
end

local function towerId(name: string): TowerTypeId
	local id = (TowerTypeId :: any)[name]
	assert(type(id) == "number", "unknown tower type " .. name)
	return id
end

local SPECS: { [TowerTypeId]: Spec } = {}
for id = 0, TowerTypeId.COUNT - 1 do
	local raw = RAW[TowerTypeId.name(id)]
	assert(raw ~= nil, "missing tower spec")

	local capacity: { [Unit]: number } = {}
	for name, value in DEFAULT_CAPACITY do
		capacity[unitId(name)] = value
	end
	for name, value in (raw.capacity or {}) :: { [string]: number } do
		capacity[unitId(name)] = value
	end

	local generate: { [Unit]: Ticks } = {}
	for name, secs in DEFAULT_GENERATE do
		generate[unitId(name)] = Ticks.fromWholeSecs(secs)
	end
	for name, secs in (raw.generate or {}) :: { [string]: number } do
		generate[unitId(name)] = Ticks.fromWholeSecs(secs)
	end

	local prerequisites: { [TowerTypeId]: number } = {}
	for name, count in (raw.prerequisites or {}) :: { [string]: number } do
		prerequisites[towerId(name)] = count
	end

	SPECS[id] = {
		downgrade = if raw.downgrade then towerId(raw.downgrade) else nil,
		delay = Ticks.fromWholeSecs(raw.delay or DEFAULT_DELAY_SECS),
		prerequisites = prerequisites,
		capacity = capacity,
		generate = generate,
		sensorRadius = raw.sensorRadius or DEFAULT_SENSOR_RADIUS,
		scoreWeight = raw.scoreWeight or 1,
		spawnable = raw.spawnable == true,
	}
end

local TowerType = {}

-- Makronun ürettiği fonksiyonlar (macros/src/lib.rs)

-- `raw_unit_capacity`: kral kalkan bonusu dahil değil.
function TowerType.rawUnitCapacity(towerType: TowerTypeId, unit: Unit): number
	return SPECS[towerType].capacity[unit] or 0
end

-- `unit_generation`: üretim periyodu (tick) ya da nil.
function TowerType.unitGeneration(towerType: TowerTypeId, unit: Unit): Ticks?
	return SPECS[towerType].generate[unit]
end

-- `prerequisite`: bu tipe yükseltmek için sahip olunması gereken `other` sayısı.
function TowerType.prerequisite(towerType: TowerTypeId, other: TowerTypeId): number
	return SPECS[towerType].prerequisites[other] or 0
end

-- `delay`: bu tipe yükseltme/düşürme süresi.
function TowerType.delay(towerType: TowerTypeId): Ticks
	return SPECS[towerType].delay
end

-- `downgrade`
function TowerType.downgrade(towerType: TowerTypeId): TowerTypeId?
	return SPECS[towerType].downgrade
end

-- `sensor_radius` (dünya birimi)
function TowerType.sensorRadius(towerType: TowerTypeId): number
	return SPECS[towerType].sensorRadius
end

-- `score_weight`
function TowerType.scoreWeight(towerType: TowerTypeId): number
	return SPECS[towerType].scoreWeight
end

-- `is_spawnable`
function TowerType.isSpawnable(towerType: TowerTypeId): boolean
	return SPECS[towerType].spawnable
end

-- `impl TowerType` (tower.rs)

-- `iter`: enum sırası.
function TowerType.all(): { TowerTypeId }
	local list = table.create(TowerTypeId.COUNT)
	for id = 0, TowerTypeId.COUNT - 1 do
		table.insert(list, id)
	end
	return list
end

-- `is_large`: kaynakta büyük kuleler kapalı, her zaman false.
function TowerType.isLarge(_towerType: TowerTypeId): boolean
	return false
end

-- `scale`
function TowerType.scale(towerType: TowerTypeId): number
	return if TowerType.isLarge(towerType) then 2 else 1
end

-- `can_upgrade_to`
function TowerType.canUpgradeTo(towerType: TowerTypeId, other: TowerTypeId): boolean
	return TowerType.downgrade(other) == towerType
end

-- `upgrades` (enum sırasıyla)
function TowerType.upgrades(towerType: TowerTypeId): { TowerTypeId }
	local list = {}
	for other = 0, TowerTypeId.COUNT - 1 do
		if TowerType.canUpgradeTo(towerType, other) then
			table.insert(list, other)
		end
	end
	return list
end

export type Prerequisite = { towerType: TowerTypeId, count: number }

-- `prerequisites` (enum sırasıyla, sıfır olmayanlar)
function TowerType.prerequisites(towerType: TowerTypeId): { Prerequisite }
	local list = {}
	for other = 0, TowerTypeId.COUNT - 1 do
		local count = TowerType.prerequisite(towerType, other)
		if count ~= 0 then
			table.insert(list, { towerType = other, count = count })
		end
	end
	return list
end

-- `TowerType::generates_mobile_units`. Kral durumunu bilmez; mümkünse `Tower.generatesMobileUnits` kullan.
function TowerType.generatesMobileUnits(towerType: TowerTypeId): boolean
	for unit = 0, Unit.COUNT - 1 do
		if Unit.isMobile(unit, towerType) and TowerType.unitGeneration(towerType, unit) ~= nil then
			return true
		end
	end
	return false
end

-- `ranged_distance`: ürettiği menzilli birimin mesafesi (ilk eşleşen, birim sırasıyla).
function TowerType.rangedDistance(towerType: TowerTypeId): number?
	for unit = 0, Unit.COUNT - 1 do
		if TowerType.unitGeneration(towerType, unit) ~= nil then
			local distance = Unit.rangedDistance(unit)
			if distance ~= nil then
				return distance
			end
		end
	end
	return nil
end

-- `ranged_damage`: bu tipin menzilli saldırıdan aldığı hasar (u8 tamsayı bölme).
function TowerType.rangedDamage(towerType: TowerTypeId, damage: number): number
	if towerType == TowerTypeId.Bunker then
		return damage // 3
	elseif towerType == TowerTypeId.Headquarters then
		return (damage * 2) // 3
	end
	return damage
end

-- `max_ranged_damage`
function TowerType.maxRangedDamage(towerType: TowerTypeId): number
	return TowerType.rangedDamage(towerType, Unit.INFINITE_DAMAGE)
end

-- `level`: sıfırdan başlayan seviye; downgrade ve ön koşullardan büyüktür.
function TowerType.level(towerType: TowerTypeId): number
	local maxLevel: number? = nil
	local function consider(other: TowerTypeId)
		local level = TowerType.level(other)
		if maxLevel == nil or level > maxLevel then
			maxLevel = level
		end
	end
	for _, prerequisite in TowerType.prerequisites(towerType) do
		consider(prerequisite.towerType)
	end
	local downgrade = TowerType.downgrade(towerType)
	if downgrade ~= nil then
		consider(downgrade)
	end
	return if maxLevel == nil then 0 else maxLevel + 1
end

-- `basis`: bu tipe yükseltilebilen en alt tip.
function TowerType.basis(towerType: TowerTypeId): TowerTypeId
	local current = towerType
	while true do
		local downgrade = TowerType.downgrade(current)
		if downgrade == nil then
			return current
		end
		current = downgrade
	end
end

-- `has_prerequisites`. `towerCounts[tip]` yoksa 0 sayılır.
function TowerType.hasPrerequisites(
	towerType: TowerTypeId,
	towerCounts: { [TowerTypeId]: number }
): boolean
	for other = 0, TowerTypeId.COUNT - 1 do
		if (towerCounts[other] or 0) < TowerType.prerequisite(towerType, other) then
			return false
		end
	end
	return true
end

-- `TowerId::CONVERSION` (tower/id.rs). Döngüsel require olmasın diye burada tekrarlandı.
local TOWER_ID_CONVERSION = 5

-- `max_range`: en büyük sensor_radius, kule birimine yukarı yuvarlanmış.
function TowerType.maxRange(): number
	local maxRadius = 0
	for id = 0, TowerTypeId.COUNT - 1 do
		maxRadius = math.max(maxRadius, TowerType.sensorRadius(id))
	end
	return (maxRadius + TOWER_ID_CONVERSION - 1) // TOWER_ID_CONVERSION
end

-- Temel tipler (downgrade'i olmayanlar), enum sırasıyla. `generate` bunlardan seçer.
local BASIC: { TowerTypeId } = {}
for id = 0, TowerTypeId.COUNT - 1 do
	if TowerType.downgrade(id) == nil then
		table.insert(BASIC, id)
	end
end
-- tower.rs: `const N: usize = 8; debug_assert_eq!(iter.clone().count(), N);`
assert(#BASIC == 8, "expected 8 basic tower types")

-- `generate(hash: u8)`: haritadaki kule tipini hash'ten seçer.
function TowerType.generate(hash: number): TowerTypeId
	return BASIC[(hash % #BASIC) + 1]
end

return table.freeze(TowerType)
