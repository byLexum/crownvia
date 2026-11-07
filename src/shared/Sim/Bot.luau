--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: server/src/bot.rs

-- Kiomet'te `server/src/bot.rs` `TowerBot` ve `impl Bot for TowerBot` → bizde bu modül.
-- Bot oyuncuyla aynı komutları üretir (`Game.Command`); komutu uygulamak `BotRepo`'nun işi.
-- Saf Luau. Rastgelelik dışarıdan verilir (`rng(): number`, [0, 1)); kaynaktaki `thread_rng`
-- yerine geçer. Rastgele seçimlerin dağılımı aynı, sayı dizisi elbette farklıdır.

local BotNames = require("./BotNames")
local Game = require("./Game")
local Pathfinding = require("./Pathfinding")
local Ticks = require("./Ticks")
local Tower = require("./Tower")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local TowerTypeId = require("./TowerTypeId")
local Unit = require("./Unit")
local Units = require("./Units")
local World = require("./World")

type Game = Game.Game
type Command = Game.Command
type Ticks = Ticks.Ticks
type TowerId = TowerId.TowerId

-- `struct War`
export type War = {
	against: number,
	remaining: Ticks,
	focus: TowerId,
}

-- `struct TowerBot`
export type Bot = {
	-- Bot bu kadar kule toplamaya çalışır.
	territorialAmbition: number,
	-- Ayrılmaya kalan süre.
	beforeQuit: Ticks,
	-- Savaştığı oyuncu ve kalan süre.
	war: War?,
}

-- kodiak `BotAction`
export type Action =
	{ kind: "Command", command: Command }
	| { kind: "None", reason: string }
	| { kind: "Quit" }

local Bot = {}

-- kodiak `BotOptions` (`TowerBot::AUTO`)
Bot.MIN_BOTS = 10
Bot.MAX_BOTS = 200
Bot.BOT_PERCENT = 80

local U32_MAX = 4294967295

-- `rng.gen_range(lo..=hi)`
local function genRange(rng: () -> number, lo: number, hi: number): number
	return lo + math.floor(rng() * (hi - lo + 1))
end

-- `rng.gen_bool(p)`
local function genBool(rng: () -> number, p: number): boolean
	return rng() < p
end

-- `IteratorRandom::choose`: eşit olasılıkla bir öğe.
local function choose<T>(rng: () -> number, list: { T }): T?
	if #list == 0 then
		return nil
	end
	return list[math.floor(rng() * #list) + 1]
end

local function setLen(set: { [any]: boolean }): number
	local n = 0
	for _ in set do
		n += 1
	end
	return n
end

-- `World::iter_towers_square` (common/src/world/towers.rs): kenarı 2*radius olan kare,
-- satır satır (y dış, x iç). Dünya dışı ve var olmayan kuleler atlanır.
local function iterTowersSquare(world: World.World, center: TowerId, radius: number): { TowerId }
	local maxCoord = TowerId.WORLD_SIZE - 1
	local cx, cy = TowerId.x(center), TowerId.y(center)
	local ids = {}
	for y = math.max(cy - radius, 0), math.min(cy + radius, maxCoord) do
		for x = math.max(cx - radius, 0), math.min(cx + radius, maxCoord) do
			local id = TowerId.new(x, y)
			if World.contains(world, id) then
				table.insert(ids, id)
			end
		end
	end
	return ids
end

-- `TowerBot::random_before_quit` (sürüm derlemesi dalı: 1800..=5400 sn).
local function randomBeforeQuit(rng: () -> number): Ticks
	return Ticks.fromWholeSecs(genRange(rng, 1800, 5400))
end

-- `TowerBot::default`
function Bot.new(rng: () -> number): Bot
	return {
		territorialAmbition = genRange(rng, 8, 12),
		beforeQuit = randomBeforeQuit(rng),
		war = nil,
	}
end

-- `Unit::damage_to_finite(unit.damage(unit.field(false, true, false), Field::Surface))`
-- toplamı (u32 doygunluklu). Önemli hasar mı yoksa sekip dönecek mi.
local function isFormidable(strength: Units.Units): boolean
	local total = 0
	for _, entry in Units.iter(strength) do
		local damage = Unit.damageToFinite(
			Unit.damage(entry.unit, Unit.field(entry.unit, false, true, false), Unit.Field.Surface)
		)
		total = math.min(total + math.min(damage * entry.count, U32_MAX), U32_MAX)
	end
	return total >= 5
end

-- `impl Bot<TowerService> for TowerBot` `fn update`. `aggression`: `settings.bot_aggression()`.
function Bot.update(
	bot: Bot,
	game: Game,
	playerId: number,
	rng: () -> number,
	aggression: number
): Action
	local world = game.world
	local player = game.players[playerId]
	assert(player ~= nil, "Bot.update: missing player")

	if not player.alive then
		bot.war = nil
		bot.beforeQuit = randomBeforeQuit(rng)
		return { kind = "Command", command = { kind = "Spawn", alias = BotNames.random(rng) } }
	end

	-- Birlik gönderebilen kulelerden rastgele biri. Küme sırası belirsiz olmasın diye sıralanır.
	local ownedIds = {}
	for id in player.towers do
		table.insert(ownedIds, id)
	end
	table.sort(ownedIds)
	local candidates = {}
	for _, id in ownedIds do
		local tower = World.get(world, id)
		if tower ~= nil and not Units.isEmpty(Tower.forceUnits(tower)) then
			table.insert(candidates, id)
		end
	end
	local randomTowerId = choose(rng, candidates)
	if randomTowerId == nil then
		-- Kral kaçarken düşman peşindeyse çökme.
		return { kind = "None", reason = "no towers" }
	end
	local randomTower = World.get(world, randomTowerId) :: Tower.Tower

	local worldPlayer = World.player(world, playerId)

	local beforeQuit = Ticks.checkedSub(bot.beforeQuit, Ticks.ONE)
	if beforeQuit ~= nil then
		bot.beforeQuit = beforeQuit
	else
		-- Dünya merkezine yakınız; ayrılıp gerçek oyunculara yer aç.
		return { kind = "Quit" }
	end

	-- Savaş sonunda biter.
	local war = bot.war
	if war ~= nil then
		local remaining = Ticks.checkedSub(war.remaining, Ticks.ONE)
		local against = game.players[war.against]
		if remaining ~= nil and against ~= nil and against.alive then
			war.remaining = remaining
		else
			bot.war = nil
		end
	end

	-- Yükseltebilir mi? Savaştaysa daha çok kalkan ister.
	local minShield = TowerType.rawUnitCapacity(randomTower.towerType, Unit.Shield)
		// (1 + (if bot.war == nil then 1 else 0))
	if Units.available(randomTower.units, Unit.Shield) >= minShield then
		local upgrades = {}
		for _, upgrade in TowerType.upgrades(randomTower.towerType) do
			if
				TowerType.hasPrerequisites(upgrade, player.towerCounts)
				and upgrade ~= TowerTypeId.Helipad
			then
				table.insert(upgrades, upgrade)
			end
		end
		local towerType = choose(rng, upgrades)
		if towerType ~= nil then
			return {
				kind = "Command",
				command = { kind = "Upgrade", towerId = randomTowerId, towerType = towerType },
			}
		end
	end

	-- Savaşı yeniden hesapla.
	if bot.war == nil and genBool(rng, 0.005) then
		-- `WarTarget`: kule sayısına göre sıralanır; eşitlikte ilk bulunan kalır.
		local bestId: number? = nil
		local bestTowers = -1
		local bestFocus: TowerId? = nil
		for _, towerId in iterTowersSquare(world, randomTowerId, 5) do
			local enemyId = (World.get(world, towerId) :: Tower.Tower).playerId
			if enemyId ~= nil and enemyId ~= playerId then
				local enemy = game.players[enemyId]
				-- `enemy_id.is_bot()`: botlara savaş açılmaz.
				if enemy ~= nil and not enemy.isBot then
					local towers = setLen(enemy.towers)
					if towers // 8 > bot.territorialAmbition and towers > bestTowers then
						bestId = enemyId
						bestTowers = towers
						bestFocus = towerId
					end
				end
			end
		end
		if bestId ~= nil and bestFocus ~= nil then
			local secs = if bestTowers > 500 then 360 else 180
			bot.war = {
				against = bestId,
				remaining = Ticks.mulFloat(Ticks.fromWholeSecs(secs), aggression),
				focus = bestFocus,
			}
			if worldPlayer.allies[bestId] then
				return {
					kind = "Command",
					command = { kind = "Alliance", with = bestId, breakAlliance = true },
				}
			end
		end
	end

	-- İttifak kurmayı düşün.
	if genBool(rng, 0.0025) then
		local with: number? = nil
		for _, towerId in iterTowersSquare(world, randomTowerId, 4) do
			local id = (World.get(world, towerId) :: Tower.Tower).playerId
			local p = if id ~= nil then game.players[id] else nil
			-- Kaynakta PlayerId'nin sondan ikinci biti ~rastgele; bizde sıralı id'nin aynı biti.
			if
				id ~= nil
				and p ~= nil
				and setLen(p.towers) // 8 <= bot.territorialAmbition
				and bit32.band(bit32.bxor(id, playerId), 2) == 0
				and not worldPlayer.allies[id]
			then
				with = id
				break
			end
		end
		if with ~= nil then
			return {
				kind = "Command",
				command = { kind = "Alliance", with = with, breakAlliance = false },
			}
		end
	end

	-- Birlik göndermeyi düşün.
	local strength = Tower.forceUnits(randomTower)
	if Units.isEmpty(strength) then
		return { kind = "None", reason = "empty force" }
	end

	-- Kral birliğin içinde mi.
	local sendingRuler = Units.contains(strength, Unit.Ruler)
	-- Birlik ciddi hasar verecek mi, yoksa sekecek mi.
	local formidable = isFormidable(strength)

	if not (formidable or sendingRuler or genBool(rng, 0.01)) then
		return { kind = "None", reason = "not formidable" }
	end

	local reusable = false
	for _, entry in Units.iter(strength) do
		if not Unit.isSingleUse(entry.unit) then
			reusable = true
			break
		end
	end
	local sendingNuke = Units.contains(strength, Unit.Nuke)
	local currentWar = bot.war

	local destinations = {}
	for _, candidateId in iterTowersSquare(world, randomTowerId, 5) do
		local candidate = World.get(world, candidateId) :: Tower.Tower
		local owner = candidate.playerId
		local ok: boolean
		if owner == playerId then
			local canSendRuler = Units.available(candidate.units, Unit.Shield)
				> Unit.damageToFinite(TowerType.maxRangedDamage(candidate.towerType))
			-- Birim kaydırılabilir:
			-- - savaşta değilken
			-- - cepheye doğru XOR kral gönderiliyorsa
			-- - kralı korumak için
			local warOk = true
			if currentWar ~= nil then
				local closer = TowerId.distanceSquared(currentWar.focus, candidateId)
					< TowerId.distanceSquared(currentWar.focus, randomTowerId)
				warOk = sendingRuler ~= closer
			end
			ok = reusable and warOk and not (sendingRuler and not canSendRuler)
		elseif
			-- Gönderilemez:
			-- - kral sahipsiz kuleye
			-- - birlik müttefik kuleye
			-- - tek kullanımlık birim sahipsiz kuleye
			sendingRuler
			or (owner ~= nil and World.player(world, owner).allies[playerId] == true and worldPlayer.allies[owner] == true)
			or (not reusable and owner == nil)
			-- Küçüklere nükleer atma (kaynakta ayrı `else if` dalı, sonuç aynı).
			or (
				sendingNuke
				and owner ~= nil
				and game.players[owner] ~= nil
				and (game.players[owner] :: Game.PlayerData).score < 2000
			)
		then
			ok = false
		elseif currentWar ~= nil then
			-- Düşmana odaklan (ya da sahipsiz kuleleri topla).
			ok = (formidable and owner == currentWar.against) or owner == nil
		else
			local enemy = if owner ~= nil then game.players[owner] else nil
			if enemy == nil then
				ok = true
			else
				-- Büyükler hedef; küçüklere fazla zarar verme; yeni el değiştirmiş olabilir.
				ok = setLen(enemy.towers) // 4 > bot.territorialAmbition
					or enemy.score > 1000
					or not formidable
					or Units.available(candidate.units, Unit.Shield) < 5
			end
		end
		if ok then
			table.insert(destinations, candidateId)
		end
	end

	local destination = choose(rng, destinations)
	if destination == nil then
		return { kind = "None", reason = "no destination" }
	end
	local destinationTower = World.get(world, destination) :: Tower.Tower

	local path = Pathfinding.findBestPath(
		Pathfinding.worldView(world),
		randomTowerId,
		destination,
		Units.maxEdgeDistance(strength),
		playerId,
		function(_)
			return true
		end
	)
	if path == nil then
		return { kind = "None", reason = "no path" }
	end

	if
		sendingRuler
		or not Tower.generatesMobileUnits(randomTower)
		or not Tower.generatesMobileUnits(destinationTower)
		or genBool(rng, 0.8)
	then
		-- `Command::deploy_force_from_path`
		return {
			kind = "Command",
			command = { kind = "DeployForce", towerId = path[1], path = path },
		}
	end
	return {
		kind = "Command",
		command = { kind = "SetSupplyLine", towerId = path[1], path = path },
	}
end

return table.freeze(Bot)
