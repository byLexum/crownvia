--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/chunk/event.rs, common/src/chunk/maintenance.rs

-- Kiomet'te `chunk/event.rs` `impl Apply<ChunkInput> for Chunk` ve
-- `chunk/maintenance.rs` `impl Apply<ChunkMaintenance> for Chunk` → bizde bu modül.
-- Doğrulama yapılmaz; doğrulanmış komutları dünyaya uygular (doğrulama `Game` içinde).
-- Alt küme: Generate, Spawn, ClearZombies, UpgradeTower, Destroy, KillPlayer.

local Force = require("./Force")
local Info = require("./Info")
local Path = require("./Path")
local Tower = require("./Tower")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local Unit = require("./Unit")
local Units = require("./Units")
local World = require("./World")

type World = World.World
type TowerId = TowerId.TowerId
type OnInfo = Info.OnInfo

local Actions = {}

-- `ChunkInput::Generate`: kuleleri haritadaki tipleriyle üretir.
function Actions.generate(world: World, towerIds: { TowerId })
	for _, id in towerIds do
		World.insert(world, id, Tower.new(id))
	end
end

-- `ChunkInput::ClearZombies`: sahipsiz kulenin birimlerini siler.
function Actions.clearZombies(world: World, towerId: TowerId)
	local tower = World.get(world, towerId)
	assert(tower ~= nil, "clearZombies: missing tower")
	if tower.playerId == nil then
		Units.clear(tower.units)
	end
end

-- `ChunkInput::Spawn`. `rank` Roblox'ta yok → her zaman nil (CLAUDE.md, bilinçli sapmalar).
-- Kaynak: rank >= Rank2 ise 8 asker, rank >= Rank5 ise ek 2 Fighter. nil < Some(_) olduğundan
-- burada her zaman 4 Soldier + 15 Shield, her yol-komşusuna ayrı birlik.
function Actions.spawn(world: World, towerId: TowerId, playerId: number, onInfo: OnInfo)
	local tower = World.get(world, towerId)
	assert(tower ~= nil, "spawn: missing tower")
	assert(tower.playerId == nil, "spawn: tower already owned")
	assert(not Units.hasRuler(tower.units), "spawn: tower has ruler")

	tower.units = Units.new()
	Tower.setPlayerId(tower, playerId)

	onInfo({ kind = "GainedTower", towerId = towerId, playerId = playerId, reason = "Spawned" })

	Units.addToTower(tower.units, Unit.Ruler, 1, tower.towerType, false)
	Units.addToTower(tower.units, Unit.Shield, math.huge, tower.towerType, false)

	-- `for unit in [Unit::Soldier, Unit::Fighter]`: rank nil iken ilk turdan sonra `break`.
	local soldiers = Units.new()
	Units.add(soldiers, Unit.Soldier, 4)
	Units.add(soldiers, Unit.Shield, 15)
	for _, neighbor in TowerId.neighbors(towerId) do
		local force = Force.new(playerId, Units.clone(soldiers), Path.new({ towerId, neighbor }))
		World.queueForces(world, Tower.sendForce(tower, force))
	end
end

-- `ChunkInput::UpgradeTower`: tip değişir, kule `delay` süresince askıya alınır.
function Actions.upgradeTower(world: World, towerId: TowerId, towerType: number)
	local tower = World.get(world, towerId)
	assert(tower ~= nil, "upgradeTower: missing tower")
	tower.towerType = towerType
	-- `NonZeroU8::new(tower_type.delay())`
	local delay = TowerType.delay(towerType)
	tower.delay = if delay == 0 then nil else delay
	-- Yeni kulenin birim kapasiteleri farklı olabilir.
	Tower.reconcileUnits(tower)
	if tower.supplyLine ~= nil and not Tower.generatesMobileUnits(tower) then
		tower.supplyLine = nil
	end
end

-- `ChunkMaintenance::Destroy`
function Actions.destroy(world: World, towerIds: { TowerId })
	for _, id in towerIds do
		local tower = World.remove(world, id)
		assert(Tower.canDestroy(tower), "destroy: tower cannot be destroyed")
	end
end

-- `ChunkMaintenance::KillPlayer`: kral ve kalkanlar silinir, kuleler sahipsiz kalır,
-- oyuncunun yoldaki birlikleri silinir. `LostRuler` ateşlenmez.
function Actions.killPlayer(world: World, playerId: number, onInfo: OnInfo)
	for _, id in World.ids(world) do
		local tower = world.towers[id]
		if tower.playerId == playerId then
			Units.subtract(tower.units, Unit.Ruler, math.huge)
			Units.subtract(tower.units, Unit.Shield, math.huge)
			Tower.setPlayerId(tower, nil)
			onInfo({
				kind = "LostTower",
				towerId = id,
				playerId = playerId,
				reason = "PlayerKilled",
			})
		end
		local function keep(list: { Force.Force }): { Force.Force }
			local kept = {}
			for _, force in list do
				if force.playerId ~= playerId then
					table.insert(kept, force)
				end
			end
			return kept
		end
		tower.inboundForces = keep(tower.inboundForces)
		tower.outboundForces = keep(tower.outboundForces)
	end
end

return table.freeze(Actions)
