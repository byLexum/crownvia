--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/unit.rs, common/src/field.rs

-- Kiomet'te `common/src/unit.rs` içindeki `enum Unit` ve `impl Unit`
-- → bizde bu modül. `common/src/field.rs` `enum Field` de burada.
--
-- Birim değerleri Rust `#[repr(u8)]` sırasıyla aynıdır. Bu sıra aynı zamanda savaşta
-- kullanım önceliğidir (önce Shield, en son Ruler).

local TowerTypeId = require("./TowerTypeId")

export type Unit = number
export type Field = number
export type Speed = number
export type Range = number
-- `UnitCategory`
export type Category = number

local NAMES: { string } = {
	"Shield",
	"Fighter",
	"Chopper",
	"Bomber",
	"Tank",
	"Soldier",
	"Shell",
	"Emp",
	"Nuke",
	"Ruler",
}

local Unit = {}

Unit.Shield = 0
Unit.Fighter = 1
Unit.Chopper = 2
Unit.Bomber = 3
Unit.Tank = 4
Unit.Soldier = 5
Unit.Shell = 6
Unit.Emp = 7
Unit.Nuke = 8
Unit.Ruler = 9

Unit.COUNT = #NAMES

-- `Unit::FIRST_ALWAYS / FIRST_MANY / FIRST_SINGLE / LAST`
Unit.FIRST_ALWAYS = Unit.Shield
Unit.FIRST_MANY = Unit.Fighter
Unit.FIRST_SINGLE = Unit.Shell
Unit.LAST = Unit.Ruler

-- `Unit::INFINITE_DAMAGE`: birimler 1..=30 hasar ya da sonsuz verir.
Unit.INFINITE_DAMAGE = 31
-- `Unit::EMP_SECONDS`
Unit.EMP_SECONDS = 60

-- `UnitCategory`
Unit.Category = table.freeze({
	Always = 0,
	Many = 1,
	Single = 2,
})
-- `UnitCategory::ALWAYS_COUNT / MANY_COUNT`
Unit.ALWAYS_COUNT = Unit.FIRST_MANY - Unit.FIRST_ALWAYS
Unit.MANY_COUNT = Unit.FIRST_SINGLE - Unit.FIRST_MANY

-- `common/src/field.rs` `enum Field` (yerden yüksekliğe göre sıralı)
Unit.Field = table.freeze({
	Surface = 0,
	Air = 1,
})

-- `enum Speed` (sıralı)
Unit.Speed = table.freeze({
	Immobile = 0,
	Slow = 1,
	Normal = 2,
	Fast = 3,
})

-- `enum Range` (sıralı)
Unit.Range = table.freeze({
	Short = 0,
	Medium = 1,
	Long = 2,
})

-- `i32::MAX`
local I32_MAX = 2147483647
-- `World::MAX_ROAD_LENGTH` (world.rs). Döngüsel require olmasın diye burada tekrarlandı.
local MAX_ROAD_LENGTH = 5

function Unit.name(unit: Unit): string
	return NAMES[unit + 1]
end

-- `Unit::iter`: Shield'dan Ruler'a sırayla.
function Unit.all(): { Unit }
	local list = table.create(Unit.COUNT)
	for unit = 0, Unit.COUNT - 1 do
		table.insert(list, unit)
	end
	return list
end

-- `Range::to_distance`
function Unit.rangeToDistance(range: Range): number
	local multiplier = if range == Unit.Range.Short
		then 5
		elseif range == Unit.Range.Medium then 8
		else 11
	return multiplier * MAX_ROAD_LENGTH
end

-- `Unit::category`
function Unit.category(unit: Unit): Category
	if unit >= Unit.FIRST_ALWAYS and unit < Unit.FIRST_MANY then
		return Unit.Category.Always
	elseif unit >= Unit.FIRST_MANY and unit < Unit.FIRST_SINGLE then
		return Unit.Category.Many
	else
		return Unit.Category.Single
	end
end

-- `Unit::max_overflow`: kule kapasitesini geçici olarak aşabileceği miktar.
function Unit.maxOverflow(unit: Unit): number
	if unit == Unit.Shield then
		return 15
	elseif unit == Unit.Soldier then
		return 10
	elseif unit == Unit.Tank then
		return 5
	elseif unit == Unit.Fighter then
		return 4
	elseif unit == Unit.Bomber then
		return 2
	elseif unit == Unit.Chopper then
		return 2
	end
	return 0
end

-- `Unit::damage`. 1..=30 ya da `INFINITE_DAMAGE`.
function Unit.damage(unit: Unit, field: Field, enemyField: Field): number
	local Air, Surface = Unit.Field.Air, Unit.Field.Surface
	if unit == Unit.Tank then
		return 3
	elseif unit == Unit.Fighter and field == Air then
		return 3
	elseif unit == Unit.Bomber and field == Air and enemyField == Surface then
		return 5
	elseif unit == Unit.Chopper and field == Air then
		return 3
	elseif unit == Unit.Nuke then
		return Unit.INFINITE_DAMAGE
	elseif unit == Unit.Shell then
		return 3
	end
	return 1
end

-- `Unit::force_ground_damage`
function Unit.forceGroundDamage(unit: Unit): number
	return Unit.damage(unit, Unit.field(unit, false, true, false), Unit.Field.Surface)
end

-- `Unit::damage_to_finite`: sonsuz hasar `i32::MAX` olur.
function Unit.damageToFinite(damage: number): number
	if damage == Unit.INFINITE_DAMAGE then
		return I32_MAX
	end
	return damage
end

-- `Unit::range`
function Unit.range(unit: Unit): Range?
	if unit == Unit.Nuke or unit == Unit.Shell then
		return Unit.Range.Short
	elseif unit == Unit.Emp then
		return Unit.Range.Medium
	end
	return nil
end

-- `Unit::is_ranged`
function Unit.isRanged(unit: Unit): boolean
	return Unit.range(unit) ~= nil
end

-- `Unit::ranged_distance`
function Unit.rangedDistance(unit: Unit): number?
	local range = Unit.range(unit)
	if range == nil then
		return nil
	end
	return Unit.rangeToDistance(range)
end

-- `Unit::is_single_use`: yoldan bağımsız atlayan birimler tek kullanımlık.
function Unit.isSingleUse(unit: Unit): boolean
	return Unit.rangedDistance(unit) ~= nil
end

-- `Unit::field`. `anyAir` yalnızca birim Shield olabilecekse önemlidir.
function Unit.field(unit: Unit, overflow: boolean, inForce: boolean, anyAir: boolean): Field
	if unit == Unit.Shield and anyAir then
		return Unit.Field.Air
	end
	if
		(
			unit == Unit.Bomber
			or unit == Unit.Chopper
			or unit == Unit.Fighter
			or unit == Unit.Shell
			or unit == Unit.Emp
			or unit == Unit.Nuke
		) and (overflow or inForce)
	then
		return Unit.Field.Air
	end
	return Unit.Field.Surface
end

-- `Unit::is_field_possible`
function Unit.isFieldPossible(unit: Unit, field: Field): boolean
	for bits = 0, 7 do
		local overflow = bit32.band(bit32.rshift(bits, 2), 1) == 1
		local inForce = bit32.band(bit32.rshift(bits, 1), 1) == 1
		local anyAir = bit32.band(bits, 1) == 1
		if Unit.field(unit, overflow, inForce, anyAir) == field then
			return true
		end
	end
	return false
end

-- `Unit::speed`. Shield yalnız birlikte (towerType nil) ya da Projector'da hareketli.
function Unit.speed(unit: Unit, towerType: number?): Speed
	if
		unit == Unit.Bomber
		or unit == Unit.Fighter
		or unit == Unit.Chopper
		or unit == Unit.Shell
	then
		return Unit.Speed.Fast
	elseif unit == Unit.Nuke or unit == Unit.Tank then
		return Unit.Speed.Slow
	elseif unit == Unit.Shield then
		if towerType == nil or towerType == TowerTypeId.Projector then
			return Unit.Speed.Fast
		end
		return Unit.Speed.Immobile
	end
	return Unit.Speed.Normal
end

-- `Unit::weight` (Chopper taşıma hesabı için)
function Unit.weight(unit: Unit): number
	if unit == Unit.Tank then
		return 2
	elseif unit == Unit.Soldier then
		return 1
	end
	return 0
end

-- `Unit::is_mobile`
function Unit.isMobile(unit: Unit, towerType: number?): boolean
	return Unit.speed(unit, towerType) ~= Unit.Speed.Immobile
end

-- `Unit::can_capture`
function Unit.canCapture(unit: Unit): boolean
	return Unit.isMobile(unit, nil) and unit ~= Unit.Shield and not Unit.isSingleUse(unit)
end

return table.freeze(Unit)
