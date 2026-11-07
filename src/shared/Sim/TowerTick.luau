--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/chunk.rs, common/src/world.rs, common/src/chunk/halt.rs

-- Kiomet'te `common/src/chunk.rs` `Chunk::tick` (kule başına tick, oyunun çekirdeği) ve
-- `common/src/world.rs` `World::tick_before_inputs` içindeki halt hesabı (`halt_path`,
-- `ChunkHaltEvent`) → bizde bu modül.
--
-- Sıra kaynakla aynı: kuleler `World.ids` sırasıyla (chunk'lar önce cy sonra cx, chunk içinde
-- önce y sonra x). Yeni birlik olayları `World.queueForces` ile sıraya alınır ve girdilerden
-- sonra (`tick_after_inputs`) uygulanır.

local Combatants = require("./Combatants")
local Force = require("./Force")
local Info = require("./Info")
local Path = require("./Path")
local Ticks = require("./Ticks")
local Tower = require("./Tower")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local Unit = require("./Unit")
local Units = require("./Units")
local World = require("./World")

type World = World.World
type Tower = Tower.Tower
type Force = Force.Force
type TowerId = TowerId.TowerId
type OnInfo = Info.OnInfo

local TowerTick = {}

local U8_MAX = 255
local U16_MAX = 65535

-- `Relationship`
type Relationship = "Comrade" | "Ally" | "Enemy"

local function relationship(world: World, a: number?, b: number?): Relationship
	if a == b then
		return "Comrade"
	end
	if a ~= nil and b ~= nil then
		local pa = World.player(world, a)
		local pb = World.player(world, b)
		if pa.allies[b] and pb.allies[a] then
			return "Ally"
		end
	end
	return "Enemy"
end

-- `Relationship::is_friendly`
local function isFriendly(rel: Relationship, rulerArrivingAtTower: boolean): boolean
	if rel == "Comrade" then
		return true
	elseif rel == "Ally" then
		return not rulerArrivingAtTower
	end
	return false
end

-- `CombatInfo::into_info_event`
local function combatInfoToEvent(
	info: Combatants.CombatInfo,
	towerId: TowerId,
	attacker: number?,
	defender: number?
): Info.InfoEvent
	if info.kind == "AttackerLostRuler" then
		assert(attacker ~= nil, "ruler must have a player id")
		return {
			kind = "LostRuler",
			towerId = towerId,
			playerId = attacker,
			killedBy = defender,
			unit = info.unit,
		}
	elseif info.kind == "DefenderLostRuler" then
		assert(defender ~= nil, "ruler must have a player id")
		return {
			kind = "LostRuler",
			towerId = towerId,
			playerId = defender,
			killedBy = attacker,
			unit = info.unit,
		}
	elseif info.kind == "Emp" then
		return {
			kind = "Emp",
			towerId = towerId,
			playerId = if info.side == "Attacker" then attacker else defender,
		}
	elseif info.kind == "NuclearExplosion" then
		return { kind = "NuclearExplosion", towerId = towerId }
	end
	return { kind = "ShellExplosion", towerId = towerId }
end

-- `u8::saturating_add`
local function satAddU8(a: number, b: number): number
	return math.min(a + b, U8_MAX)
end

-- `World::halt_path`: yol üzerinde yok edilmiş ya da yeni müttefike ait kule var mı.
local function pathNeedsHalt(
	world: World,
	ids: { TowerId },
	fromIndex: number,
	playerId: number
): boolean
	local player = World.player(world, playerId)
	local noNewAlliances = next(player.newAlliances) == nil
	for i = fromIndex, #ids do
		local tower = World.get(world, ids[i])
		if tower == nil then
			-- Kule yok edildi.
			return true
		end
		if not noNewAlliances and tower.playerId ~= nil and player.newAlliances[tower.playerId] then
			-- Yeni ittifak.
			return true
		end
	end
	return false
end

-- `World::tick_before_inputs` içindeki halt bölümü (`ChunkHaltEvent`).
-- Kaynak önce tüm olayları toplar, sonra uygular; burada da önce toplanır.
function TowerTick.halt(world: World)
	type HaltForce = { force: Force }
	local haltForces: { Force } = {}
	local haltSupply: { Tower } = {}
	for _, id in World.ids(world) do
		local tower = world.towers[id]
		for _, force in tower.inboundForces do
			local playerId = force.playerId
			if playerId ~= nil then
				-- `force.path().iter().skip(2)`
				if pathNeedsHalt(world, force.path.ids, 3, playerId) then
					table.insert(haltForces, force)
				end
			end
		end
		local supplyLine = tower.supplyLine
		if supplyLine ~= nil then
			assert(tower.playerId ~= nil, "supply line without player")
			if pathNeedsHalt(world, supplyLine.ids, 1, tower.playerId) then
				table.insert(haltSupply, tower)
			end
		end
	end
	for _, force in haltForces do
		Force.halt(force)
	end
	for _, tower in haltSupply do
		tower.supplyLine = nil
	end
end

-- Birlikler arası çarpışma (`// Force vs. force.`)
local function forceVsForce(world: World, tower: Tower, onInfo: OnInfo)
	if #tower.inboundForces == 0 or #tower.outboundForces == 0 then
		return
	end

	local keptInbound = {}
	for _, inbound in tower.inboundForces do
		local allSamePlayer = true
		for _, outbound in tower.outboundForces do
			if inbound.playerId ~= outbound.playerId then
				allSamePlayer = false
				break
			end
		end
		if allSamePlayer then
			-- Optimizasyon: büyük bölgelerde hesap yapma.
			table.insert(keptInbound, inbound)
			continue
		end

		local inboundRequired = Force.progressRequired(inbound)
		local inboundPathProgress = math.max(
			inboundRequired - satAddU8(inbound.pathProgress, Force.progressPerTick(inbound)),
			0
		)
		local inboundNextPathProgress = math.max(inboundRequired - inbound.pathProgress, 0)

		local inboundSurvived = true
		local keptOutbound = {}
		for _, outbound in tower.outboundForces do
			local keep = true
			if
				inboundSurvived
				and Force.currentDestination(outbound) == Force.currentSource(inbound)
				and outbound.playerId ~= inbound.playerId
			then
				local outboundRequired = Force.progressRequired(outbound)
				local effInbound = inboundPathProgress * outboundRequired
				local effInboundNext = inboundNextPathProgress * outboundRequired
				local effOutbound = outbound.pathProgress * inboundRequired
				local effOutboundNext = satAddU8(
					outbound.pathProgress,
					Force.progressPerTick(outbound)
				) * inboundRequired
				-- u16 çarpımları en fazla 255*255 = 65025, taşmaz.
				assert(effInbound <= U16_MAX and effOutboundNext <= U16_MAX, "u16 overflow")

				local overlap = math.max(effInbound, effOutbound)
					<= math.min(effInboundNext, effOutboundNext)
				if
					overlap
					and not isFriendly(
						relationship(world, inbound.playerId, outbound.playerId),
						false
					)
				then
					-- Olayları yalnız bir taraf üretir (savaş değişmeli olmasa bile tutarlılık).
					local authoritative = Force.currentDestination(inbound)
						> Force.currentDestination(outbound)
					local position = Force.currentSource(inbound)
					local winner = Combatants.fight(
						Combatants.force(inbound.units),
						Combatants.force(outbound.units),
						function(info)
							if authoritative then
								onInfo(
									combatInfoToEvent(
										info,
										position,
										inbound.playerId,
										outbound.playerId
									)
								)
							end
						end
					)
					inboundSurvived = inboundSurvived and winner == "Attacker"
					keep = winner == "Defender"
				end
			end
			if keep then
				table.insert(keptOutbound, outbound)
			end
		end
		tower.outboundForces = keptOutbound

		if inboundSurvived then
			table.insert(keptInbound, inbound)
		end
	end
	tower.inboundForces = keptInbound
end

-- Birliğin kuleye varışı (`// Force vs. tower.` döngü gövdesi)
local function forceArrives(
	world: World,
	towerId: TowerId,
	tower: Tower,
	force: Force,
	onInfo: OnInfo
)
	local towerPlayerId = tower.playerId
	if towerPlayerId ~= nil or not Units.isEmpty(tower.units) then
		local forcePlayerId = force.playerId
		if
			not isFriendly(
				relationship(world, towerPlayerId, forcePlayerId),
				Units.hasRuler(force.units)
			)
		then
			local towerEmped = false
			local winner = Combatants.fight(
				Combatants.force(force.units),
				Combatants.tower(tower.towerType, tower.units),
				function(info)
					if info.kind == "Emp" and info.side == "Attacker" then
						towerEmped = true
					end
					onInfo(combatInfoToEvent(info, towerId, forcePlayerId, towerPlayerId))
				end
			)

			if towerEmped then
				-- `tower.delay.max(Some(emp_delay))`
				local empDelay = Ticks.fromWholeSecs(Unit.EMP_SECONDS)
				tower.delay = math.max(tower.delay or 0, empDelay)
			end

			if winner ~= "Attacker" and forcePlayerId ~= nil then
				onInfo({ kind = "LostForce", towerId = towerId, playerId = forcePlayerId })
			end

			if winner ~= "Defender" then
				if towerPlayerId ~= nil then
					if winner == "Attacker" then
						onInfo({
							kind = "LostTower",
							towerId = towerId,
							playerId = towerPlayerId,
							reason = "CapturedBy",
							by = forcePlayerId,
						})
					else
						onInfo({
							kind = "LostTower",
							towerId = towerId,
							playerId = towerPlayerId,
							reason = "DestroyedBy",
							by = forcePlayerId,
						})
					end
				end

				local newPlayerId: number? = nil
				if forcePlayerId ~= nil and winner == "Attacker" then
					onInfo({
						kind = "GainedTower",
						towerId = towerId,
						playerId = forcePlayerId,
						reason = "CapturedFrom",
						from = towerPlayerId,
					})
					newPlayerId = forcePlayerId
				end

				-- Zombiler nükleerle vurulunca çökmesin.
				if tower.playerId ~= nil or newPlayerId ~= nil then
					Tower.setPlayerId(tower, newPlayerId)
				end

				-- Ele geçirilmedi, havaya uçtu: temel tipe düşer.
				if tower.playerId == nil then
					tower.towerType = TowerType.basis(tower.towerType)
					tower.delay = nil
				end
			end
		end
		-- Aksi halde birlik yoluna devam edebilir (ya da yolculuğa başlar).
	elseif force.playerId ~= nil and Units.isAlive(force.units) then
		-- Birlik bir kule keşfetti.
		local forcePlayerId = force.playerId :: number
		onInfo({
			kind = "GainedTower",
			towerId = towerId,
			playerId = forcePlayerId,
			reason = "Explored",
		})
		Tower.setPlayerId(tower, forcePlayerId)
		Units.reconcile(tower.units, tower.towerType, tower.playerId ~= nil)
	end

	local rel: Relationship = relationship(world, force.playerId, tower.playerId)

	if Units.isEmpty(force.units) then
		-- Düşür.
		return
	elseif force.fuel == 0 then
		-- Yakıt bitti.
		if force.playerId ~= nil then
			onInfo({ kind = "LostForce", towerId = towerId, playerId = force.playerId })
		end
	elseif
		(rel == "Ally" or rel == "Comrade")
		and Force.tryMoveOn(
			force,
			tower.towerType,
			tower.units,
			if rel == "Ally" then tower.playerId else nil,
			tower.supplyLine
		)
	then
		local cramped = false
		if Units.isMany(force.units) then
			local sameDestination = 0
			local destination = Force.currentDestination(force)
			for _, outbound in tower.outboundForces do
				if Force.currentDestination(outbound) == destination then
					sameDestination += 1
				end
			end
			cramped = sameDestination >= 8
		end
		if cramped then
			-- Sıkışma.
			if force.playerId ~= nil then
				onInfo({ kind = "LostForce", towerId = towerId, playerId = force.playerId })
			end
		else
			World.queueForces(world, Tower.sendForce(tower, force))
		end
	elseif isFriendly(rel, Units.hasRuler(force.units)) then
		-- Birlik vardı. Taşma yalnız gerçek oyuncu kulelerinde.
		Units.addUnitsToTower(tower.units, force.units, tower.towerType, tower.playerId ~= nil)
	elseif Units.available(force.units, Unit.Ruler) > 0 then
		local forcePlayerId = force.playerId
		assert(forcePlayerId ~= nil, "force with ruler didn't have player")
		onInfo({
			kind = "LostRuler",
			towerId = towerId,
			playerId = forcePlayerId,
			killedBy = nil,
			unit = Unit.Shield,
		})
	end
end

-- `Chunk::tick` tek kule gövdesi
local function tickTower(world: World, towerId: TowerId, tower: Tower, onInfo: OnInfo)
	-- Sahipsiz kulede kral olmamalı.
	assert(tower.playerId ~= nil or not Units.hasRuler(tower.units), "unowned tower has ruler")

	-- Chunk'a göre tick kaydırması.
	local tick = Ticks.wrappingAdd(world.tick, TowerId.chunkTickOffset(towerId))
	local downgradeTime = Ticks.every(tick, Ticks.fromWholeSecs(60))

	local deploy = false
	if Ticks.every(tick, Ticks.fromWholeSecs(if tower.playerId ~= nil then 30 else 10)) then
		deploy = (Tower.diminishUnitsIfDeadOrOverflow(tower) ~= 0 and Tower.active(tower)) or deploy
	end

	-- Ya gecikme ya üretim/düşme, ikisi birden değil.
	if tower.delay ~= nil then
		local delay = tower.delay - 1
		tower.delay = if delay == 0 then nil else delay
	elseif tower.playerId ~= nil then
		for unit = 0, Unit.COUNT - 1 do
			-- Kaynakta `tower.tower_type.unit_generation(unit)` (kule tipinin; kral kontrolü yok).
			local period = TowerType.unitGeneration(tower.towerType, unit)
			if period ~= nil and Ticks.every(tick, period) then
				-- 2 ekle, eklenenlerden en fazla 1'ini geri al (yer var mı diye bakmak için).
				local added = Units.addToTower(tower.units, unit, 2, tower.towerType, false)
				Units.subtract(tower.units, unit, math.max(added - 1, 0))
				deploy = (Unit.isMobile(unit, tower.towerType) and added < 2) or deploy
			end
		end
	else
		local downgrade = TowerType.downgrade(tower.towerType)
		if downgrade ~= nil and downgradeTime then
			tower.towerType = downgrade
			Tower.reconcileUnits(tower)
		end
	end

	if deploy and not Units.hasRuler(tower.units) then
		local supplyLine = tower.supplyLine
		if supplyLine ~= nil then
			-- Nükleer ikmal hattına asker gönderme. `Option` karşılaştırması: None < Some.
			local unitsRange = Units.maxEdgeDistance(Tower.forceUnits(tower))
			local towerRange = TowerType.rangedDistance(tower.towerType)
			local ok = if towerRange == nil
				then true
				elseif unitsRange == nil then false
				else unitsRange >= towerRange
			if ok then
				World.queueForces(world, Tower.deployForce(tower, Path.clone(supplyLine)))
			end
		end
	end

	forceVsForce(world, tower, onInfo)

	-- `extract_if(|f| f.tick(tower_id))`: varanlar sırayla çıkarılır.
	local arrived: { Force } = {}
	local remaining: { Force } = {}
	for _, force in tower.inboundForces do
		if Force.tick(force, towerId) then
			table.insert(arrived, force)
		else
			table.insert(remaining, force)
		end
	end
	tower.inboundForces = remaining
	for _, force in arrived do
		forceArrives(world, towerId, tower, force, onInfo)
	end

	-- Giden aynalar: varınca atılır.
	local outbound: { Force } = {}
	for _, force in tower.outboundForces do
		if not Force.rawTick(force) then
			table.insert(outbound, force)
		end
	end
	tower.outboundForces = outbound
end

-- Tüm kuleler, kaynak sırasıyla (`for chunk in chunks { chunk.tick(..) }`).
function TowerTick.tickAll(world: World, onInfo: OnInfo)
	for _, id in World.ids(world) do
		local tower = world.towers[id]
		if tower ~= nil then
			tickTower(world, id, tower, onInfo)
		end
	end
end

return table.freeze(TowerTick)
