--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/units.rs

-- Kiomet'te `common/src/units.rs` içindeki `struct Units` → bizde bu modül.
--
-- Yapı kaynakla aynı:
--   always: Shield sayısı (her zaman var)
--   either: ya Many (Fighter, Chopper, Bomber, Tank, Soldier sayıları)
--           ya Single (tek bir Shell/Emp/Nuke/Ruler türü ve sayısı, sayı > 0)
-- Sonuç: kral (Single) bulunan küme asker vb. (Many) tutamaz.
--
-- Sayılar Rust'ta `u8`. Release derlemesinde `+=` taşması sarmalıdır; burada da `% 256`.
-- Pratikte kapasite 255 ile sınırlı olduğundan taşma yalnız birlik içi aşırı uç durumda olur.

local TowerType = require("./TowerType")
local Unit = require("./Unit")

type Unit = Unit.Unit

export type Units = {
	shield: number,
	-- nil → Many durumu. Aksi halde Single durumundaki birim.
	single: Unit?,
	singleCount: number,
	-- Many sayıları, indeks 1..MANY_COUNT = Fighter..Soldier. Single durumunda hepsi 0.
	many: { number },
}

export type Entry = { unit: Unit, count: number }

local Units = {}

-- `Units::CAPACITY` (u8::MAX)
Units.CAPACITY = 255
-- `Tower::RULER_SHIELD_BOOST` (tower.rs). Döngüsel require olmasın diye burada.
Units.RULER_SHIELD_BOOST = 10

local MANY_COUNT = Unit.MANY_COUNT
local FIRST_MANY = Unit.FIRST_MANY
local Category = Unit.Category

local function wrapU8(value: number): number
	return value % 256
end

local function zeroMany(): { number }
	local many = table.create(MANY_COUNT, 0)
	return many
end

-- `Units::default`
function Units.new(): Units
	return {
		shield = 0,
		single = nil,
		singleCount = 0,
		many = zeroMany(),
	}
end

-- `Clone`
function Units.clone(units: Units): Units
	return {
		shield = units.shield,
		single = units.single,
		singleCount = units.singleCount,
		many = table.clone(units.many),
	}
end

-- `PartialEq`
function Units.equals(a: Units, b: Units): boolean
	if a.shield ~= b.shield or a.single ~= b.single or a.singleCount ~= b.singleCount then
		return false
	end
	for i = 1, MANY_COUNT do
		if a.many[i] ~= b.many[i] then
			return false
		end
	end
	return true
end

-- `Units::is_many`
function Units.isMany(units: Units): boolean
	return units.single == nil
end

-- `Units::index` / `available`
function Units.available(units: Units, unit: Unit): number
	local category = Unit.category(unit)
	if category == Category.Always then
		return units.shield
	elseif category == Category.Many then
		if units.single ~= nil then
			return 0
		end
		return units.many[unit - FIRST_MANY + 1]
	else
		if units.single == unit then
			return units.singleCount
		end
		return 0
	end
end

-- `Units::has_ruler`
function Units.hasRuler(units: Units): boolean
	return Units.available(units, Unit.Ruler) > 0
end

-- `Units::contains`
function Units.contains(units: Units, unit: Unit): boolean
	return Units.available(units, unit) > 0
end

-- `Units::capacity`: kral kalkan bonusu dahil. `towerType` nil ise (birlik) 255.
function Units.capacity(units: Units, unit: Unit, towerType: number?): number
	if towerType == nil then
		return Units.CAPACITY
	end
	local raw = TowerType.rawUnitCapacity(towerType, unit)
	if unit == Unit.Shield and Units.hasRuler(units) then
		raw += Units.RULER_SHIELD_BOOST
	end
	return math.min(Units.CAPACITY, raw)
end

-- `Units::space_remaining`
local function spaceRemaining(
	units: Units,
	unit: Unit,
	towerType: number?,
	overflow: boolean
): number
	local category = Unit.category(unit)
	if category == Category.Many then
		-- Many, Single'ı ezemez.
		if units.single ~= nil then
			return 0
		end
	elseif category == Category.Single then
		-- Single, daha yüksek öncelikli Single'ı ezemez.
		if units.single ~= nil and units.single > unit then
			return 0
		end
	end
	local limit = Units.capacity(units, unit, towerType)
		+ (if overflow then Unit.maxOverflow(unit) else 0)
	return math.max(limit - Units.available(units, unit), 0)
end

-- `Units::add_inner`: eklenen miktarı döner.
local function addInner(
	units: Units,
	unit: Unit,
	count: number,
	towerType: number?,
	overflow: boolean
): number
	local added = math.min(count, spaceRemaining(units, unit, towerType, overflow))
	if added == 0 then
		return 0
	end
	local addedU8 = wrapU8(added)

	local category = Unit.category(unit)
	if category == Category.Always then
		units.shield = wrapU8(units.shield + addedU8)
	elseif category == Category.Many then
		local index = unit - FIRST_MANY + 1
		units.many[index] = wrapU8(units.many[index] + addedU8)
	else
		if units.single == nil then
			-- Many → Single: Many birimleri silinir (kaynakta `self.either = Single(..)`).
			units.single = unit
			units.singleCount = addedU8
			units.many = zeroMany()
		elseif units.single == unit then
			units.singleCount = wrapU8(units.singleCount + addedU8)
		else
			-- Daha düşük öncelikli Single yerine yenisi geçer.
			units.single = unit
			units.singleCount = addedU8
		end
	end
	return added
end

-- `Units::clear`
function Units.clear(units: Units)
	units.shield = 0
	units.single = nil
	units.singleCount = 0
	units.many = zeroMany()
end

-- `Units::is_empty`
function Units.isEmpty(units: Units): boolean
	return Units.equals(units, Units.new())
end

-- `Units::subtract`: çıkarılan miktarı döner.
function Units.subtract(units: Units, unit: Unit, count: number): number
	local available = Units.available(units, unit)
	local subtracted = math.min(count, available)
	if subtracted == 0 then
		return 0
	end

	local category = Unit.category(unit)
	if category == Category.Always then
		units.shield -= subtracted
	elseif category == Category.Many then
		local index = unit - FIRST_MANY + 1
		units.many[index] -= subtracted
	else
		units.singleCount -= subtracted
		if units.singleCount == 0 then
			-- Sıfır Single geçersiz; varsayılan (boş Many) olur.
			units.single = nil
			units.many = zeroMany()
		end
	end
	return subtracted
end

-- `Units::iter`: sıfır olmayanlar, birim sırasıyla.
function Units.iter(units: Units): { Entry }
	local list = {}
	for unit = 0, Unit.COUNT - 1 do
		local count = Units.available(units, unit)
		if count ~= 0 then
			table.insert(list, { unit = unit, count = count })
		end
	end
	return list
end

-- `Units::add`: birliğe (kule değil) ekler, aşım serbest.
function Units.add(units: Units, unit: Unit, count: number): number
	return addInner(units, unit, count, nil, true)
end

-- `Units::add_to_tower`
function Units.addToTower(
	units: Units,
	unit: Unit,
	count: number,
	towerType: number,
	overflow: boolean
): number
	return addInner(units, unit, count, towerType, overflow)
end

-- `Units::add_units_to_tower`: tek kullanımlık olmayanları kuleye ekler.
function Units.addUnitsToTower(units: Units, other: Units, towerType: number, hasPlayer: boolean)
	for _, entry in Units.iter(other) do
		if not Unit.isSingleUse(entry.unit) then
			Units.addToTower(units, entry.unit, entry.count, towerType, hasPlayer)
		end
	end
end

-- `Units::reconcile`: yeni kule tipine göre birimleri yeniden yerleştirir.
function Units.reconcile(units: Units, towerType: number, hasPlayer: boolean)
	local old = Units.clone(units)
	Units.clear(units)
	Units.addUnitsToTower(units, old, towerType, hasPlayer)
end

-- `Units::len`
function Units.len(units: Units): number
	local total = 0
	for _, entry in Units.iter(units) do
		total += entry.count
	end
	return total
end

-- `Units::is_alive`: kule ele geçirebilir mi (tek kullanımlık ve Shield dışında birim var mı).
function Units.isAlive(units: Units): boolean
	for _, entry in Units.iter(units) do
		if not (Unit.isSingleUse(entry.unit) or entry.unit == Unit.Shield) then
			return true
		end
	end
	return false
end

-- `Units::max_edge_distance`: hareketli birimlerin menzili (hepsi aynı olmalı). Boşsa nil.
function Units.maxEdgeDistance(units: Units): number?
	local entries = Units.iter(units)
	if #entries == 0 then
		return nil
	end
	return Unit.rangedDistance(entries[1].unit)
end

-- `Units::random_units` çevrilmedi: kaynakta yalnız `chunk/benchmark.rs` kullanıyor.

return table.freeze(Units)
