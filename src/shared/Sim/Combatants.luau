--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/combatants.rs

-- Kiomet'te `common/src/combatants.rs` `Combatants::fight` → bizde `Combatants.fight`.
-- İki taraf birimlerini yerinde değiştirerek savaşır. En fazla biri kule olabilir; kural gereği
-- kule savunandır. Tek işaretli tamsayı `damage`: saldıran +, savunan − yönde ekler.
-- Rust'taki `ptr::eq(me, attacker)` yerine taraf açıkça (isAttacker) taşınır.

local TowerType = require("./TowerType")
local Unit = require("./Unit")
local Units = require("./Units")

type Units = Units.Units
type Unit = Unit.Unit

export type Combatant = {
	units: Units,
	-- nil → birlik
	towerType: number?,
}

-- `CombatSide`
export type Side = "Attacker" | "Defender"

-- `CombatInfo`
export type CombatInfo =
	{ kind: "AttackerLostRuler", unit: Unit }
	| { kind: "DefenderLostRuler", unit: Unit }
	| { kind: "Emp", side: Side }
	| { kind: "NuclearExplosion" }
	| { kind: "ShellExplosion" }

local Combatants = {}

local I32_MAX = 2147483647
local Field = Unit.Field

-- `Combatants::tower`
function Combatants.tower(towerType: number, units: Units): Combatant
	return { towerType = towerType, units = units }
end

-- `Combatants::force`
function Combatants.force(units: Units): Combatant
	return { towerType = nil, units = units }
end

-- `Combatants::add` (yalnız testler için, kaynakta da `#[cfg(test)]`)
function Combatants.add(c: Combatant, unit: Unit, count: number): number
	if c.towerType ~= nil then
		return Units.addToTower(c.units, unit, count, c.towerType, false)
	end
	return Units.add(c.units, unit, count)
end

type Entry = { unit: Unit, count: number }

-- `unused_units`: kullanımdaki (son) birim sayılmaz.
local function unusedUnits(me: Combatant, last: Unit?): { Entry }
	local list = {}
	for _, entry in Units.iter(me.units) do
		local count = entry.count
		if last == entry.unit and not Unit.isSingleUse(entry.unit) then
			count -= 1
		end
		if count ~= 0 then
			table.insert(list, { unit = entry.unit, count = count })
		end
	end
	return list
end

-- `Combatants::fight`. Kazanan taraf ya da nil (beraberlik) döner.
function Combatants.fight(
	attacker: Combatant,
	defender: Combatant,
	onInfo: (CombatInfo) -> ()
): Side?
	assert(attacker.towerType == nil or defender.towerType == nil, "two towers")

	-- `hack`: Shield kuleye karşı saldırıda kullanılmaz.
	if attacker.towerType ~= nil then
		Units.subtract(defender.units, Unit.Shield, math.huge)
	end
	if defender.towerType ~= nil then
		Units.subtract(attacker.units, Unit.Shield, math.huge)
	end

	local damage = 0
	local lastAttacker: Unit? = nil
	local lastDefender: Unit? = nil
	local emped, nuked, shelled = false, false, false

	-- `replace_unit`: yeni birimi sahaya sürer, öncekini öldürür. Yeni `my_last` döner.
	local function replaceUnit(
		me: Combatant,
		isAttacker: boolean,
		myLast: Unit?,
		enemyLast: Unit?,
		unit: Unit?
	): Unit?
		local side: Side = if isAttacker then "Attacker" else "Defender"

		-- Tek kullanımlıklar hemen tüketilir.
		if unit ~= nil and Unit.isSingleUse(unit) then
			if unit == Unit.Emp then
				if not emped then
					emped = true
					onInfo({ kind = "Emp", side = side })
				end
			elseif unit == Unit.Nuke then
				if not nuked then
					nuked = true
					onInfo({ kind = "NuclearExplosion" })
				end
			elseif unit == Unit.Shell then
				if not shelled then
					shelled = true
					onInfo({ kind = "ShellExplosion" })
				end
			end
			local subtracted = Units.subtract(me.units, unit, 1)
			assert(subtracted == 1, "replaceUnit: single use not present")
		end

		-- Yeni birim gerekti, öncekini öldür.
		if myLast ~= nil and not Unit.isSingleUse(myLast) then
			if myLast == Unit.Ruler then
				assert(enemyLast ~= nil, "ruler killed without cause")
				if isAttacker then
					onInfo({ kind = "AttackerLostRuler", unit = enemyLast })
				else
					onInfo({ kind = "DefenderLostRuler", unit = enemyLast })
				end
			end
			local subtracted = Units.subtract(me.units, myLast, 1)
			assert(subtracted == 1, "replaceUnit: last unit not present")
		end

		-- Beraberlikte kralı öldüreni silme.
		if unit ~= nil then
			return unit
		end
		return myLast
	end

	-- `damage_against`. `enemyIsAttacker`: hasarı alan taraf saldıran mı.
	local function damageAgainst(
		unit: Unit,
		unitField: number,
		enemy: Combatant,
		enemyIsAttacker: boolean,
		enemyField: number,
		prevDamage: number
	): number
		local unitDamage = Unit.damage(unit, unitField, enemyField)
		if Unit.isRanged(unit) and enemy.towerType ~= nil then
			-- Nükleer siloları tek atışta yıkmaz.
			unitDamage = TowerType.rangedDamage(enemy.towerType, unitDamage)
		end
		local d = Unit.damageToFinite(unitDamage)
		local dir = if enemyIsAttacker then -1 else 1
		-- Nükleer yıkıma karşı nükleerle savunulamaz.
		if prevDamage * -dir > I32_MAX // 2 then
			d = math.min(d, 1000)
		end
		return d * dir
	end

	for _, field in { Field.Air, Field.Surface } do
		while true do
			local function nextUnitInner(
				me: Combatant,
				last: Unit?,
				anyAir: boolean
			): (Unit?, number)
				local t = me.towerType
				for _, entry in unusedUnits(me, last) do
					local overflow = t ~= nil
						and entry.count > Units.capacity(me.units, entry.unit, t)
					local unitField = Unit.field(entry.unit, overflow, t == nil, anyAir)
					if unitField >= field then
						return entry.unit, unitField
					end
				end
				return nil, 0
			end

			-- Shield'in havada olup olmadığına karar vermek için en fazla iki kez çağrılır.
			local function nextUnit(me: Combatant, last: Unit?): (Unit?, number)
				local unit, unitField = nextUnitInner(me, last, false)
				if unit ~= nil and field == Field.Air then
					return nextUnitInner(me, last, true)
				end
				return unit, unitField
			end

			local nextAttacker: Unit?, attackerField = nil, 0
			local nextDefender: Unit?, defenderField = nil, 0
			if damage < 0 then
				nextAttacker, attackerField = nextUnit(attacker, lastAttacker)
			elseif damage > 0 then
				nextDefender, defenderField = nextUnit(defender, lastDefender)
			else
				-- `(next_defender.and(next_attacker), None)`
				local a, af = nextUnit(attacker, lastAttacker)
				local d = nextUnit(defender, lastDefender)
				if d ~= nil then
					nextAttacker, attackerField = a, af
				end
			end

			if nextAttacker ~= nil then
				lastAttacker = replaceUnit(attacker, true, lastAttacker, lastDefender, nextAttacker)
				damage += damageAgainst(nextAttacker, attackerField, defender, false, field, damage)
			elseif nextDefender ~= nil then
				lastDefender =
					replaceUnit(defender, false, lastDefender, lastAttacker, nextDefender)
				damage += damageAgainst(nextDefender, defenderField, attacker, true, field, damage)
			else
				break
			end
		end
	end

	-- Birim kalmadı, sonuncuyu öldür.
	local function nextUnusedUnit(me: Combatant, last: Unit?): Unit?
		local list = unusedUnits(me, last)
		return if #list > 0 then list[1].unit else nil
	end
	local nextAttacker = nextUnusedUnit(attacker, lastAttacker)
	local nextDefender = nextUnusedUnit(defender, lastDefender)
	assert(nextAttacker == nil or nextDefender == nil, "only 1 side should remain")

	local ordering: { Side } = { "Attacker", "Defender" }
	if nextDefender ~= nil then
		ordering = { "Defender", "Attacker" }
	end
	for _, side in ordering do
		if side == "Attacker" and damage <= 0 then
			if nextAttacker ~= nil then
				damage += damageAgainst(
					nextAttacker,
					Field.Surface,
					defender,
					false,
					Field.Surface,
					damage
				)
			end
			lastAttacker = replaceUnit(attacker, true, lastAttacker, lastDefender, nextAttacker)
		elseif side == "Defender" and damage >= 0 then
			if nextDefender ~= nil then
				damage += damageAgainst(
					nextDefender,
					Field.Surface,
					attacker,
					true,
					Field.Surface,
					damage
				)
			end
			lastDefender = replaceUnit(defender, false, lastDefender, lastAttacker, nextDefender)
		end
	end

	local attackerAlive = Units.isAlive(attacker.units)
	local defenderAlive = Units.isAlive(defender.units)
	assert(not (attackerAlive and defenderAlive), "both alive")

	if attackerAlive or (attacker.towerType ~= nil and damage >= 0) then
		return "Attacker"
	elseif defenderAlive or (defender.towerType ~= nil and damage <= 0) then
		return "Defender"
	end
	return nil
end

return table.freeze(Combatants)
