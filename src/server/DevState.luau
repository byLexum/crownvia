--!strict
-- Yalnız Studio: MCP ile test için oyunun kendi script ortamında çalışan sabit test komutları.
-- `ServerStorage.RobgameDev` (BindableFunction) üzerinden çağrılır:
--   ServerStorage.RobgameDev:Invoke("summary")
--   ServerStorage.RobgameDev:Invoke("attackDummy")
--   ServerStorage.RobgameDev:Invoke("defendDummy")  -- düşman saldırısı, savunma tutar (çatışma efekti)
--   ServerStorage.RobgameDev:Invoke("tower", towerId)
--   ServerStorage.RobgameDev:Invoke("assassinate")  -- ölüm ekranı testi
--   ServerStorage.RobgameDev:Invoke("bridge")       -- iki oyunculu savaş testi
--   ServerStorage.RobgameDev:Invoke("bots")         -- bot durumu + adım süresi
--   ServerStorage.RobgameDev:Invoke("setBots", n)   -- sabit bot sayısı (nil → otomatik)
--   ServerStorage.RobgameDev:Invoke("allyMe", id)   -- `id` oyuncusu ilk gerçek oyuncuya ittifak ister
--   ServerStorage.RobgameDev:Invoke("allies", id)   -- oyuncunun ittifak istekleri
--   ServerStorage.RobgameDev:Invoke("partyRoom", n) -- parti odası taklidi (n bot, kurucu ilk oyuncu)
--   ServerStorage.RobgameDev:Invoke("ranged", "Shell"|"Emp"|"Nuke") -- menzilli birim testi hazırlığı
-- Canlı sunucuda hiçbir şey kurulmaz; oyun kurallarına etkisi yoktur.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local BotRepo = require(Sim.BotRepo)
local Force = require(Sim.Force)
local Game = require(Sim.Game)
local Path = require(Sim.Path)
local Tower = require(Sim.Tower)
local TowerId = require(Sim.TowerId)
local TowerType = require(Sim.TowerType)
local TowerTypeId = require(Sim.TowerTypeId)
local Unit = require(Sim.Unit)
local Units = require(Sim.Units)
local Visibility = require(Sim.Visibility)
local World = require(Sim.World)

local DevState = {}

export type StepStats = {
	steps: number,
	totalMs: number,
	maxMs: number,
	-- Çoğaltma (görüş + fark + gönderim) ayrı ölçülür.
	replMs: number,
	replMaxMs: number,
	replSteps: number,
}

local function unitsString(units: Units.Units): string
	local parts = {}
	for _, entry in Units.iter(units) do
		table.insert(parts, Unit.name(entry.unit) .. "=" .. entry.count)
	end
	return table.concat(parts, ",")
end

local function towerString(sim: Game.Game, id: number): string
	local tower = World.get(sim.world, id)
	if tower == nil then
		return TowerId.toString(id) .. " (not generated)"
	end
	return string.format(
		"%s %s owner=%s units={%s} inbound=%d outbound=%d",
		TowerId.toString(id),
		TowerTypeId.name(tower.towerType),
		tostring(tower.playerId),
		unitsString(tower.units),
		#tower.inboundForces,
		#tower.outboundForces
	)
end

-- Senaryo: ilk gerçek oyuncunun askerli bir kulesinin sahipsiz komşusunu sahte rakibe ver
-- (1 asker), sonra oraya `DeployForce` gönder.
local function attackDummy(sim: Game.Game, simIds: { [Player]: number }): string
	local _, me = next(simIds)
	if me == nil then
		return "no player"
	end
	local data = sim.players[me]
	local source, target
	for id in data.towers do
		local tower = World.get(sim.world, id) :: Tower.Tower
		if Units.available(tower.units, Unit.Soldier) >= 3 then
			for _, n in TowerId.neighbors(id) do
				local other = World.get(sim.world, n)
				-- Asker üretmeyen hedef seç (ele geçirme senaryosu için).
				if
					other
					and other.playerId == nil
					and TowerType.unitGeneration(other.towerType, Unit.Soldier) == nil
				then
					source, target = id, n
					break
				end
			end
		end
		if source then
			break
		end
	end
	if source == nil or target == nil then
		return "no source/target found"
	end
	local dummy = Game.playerJoined(sim, true)
	sim.players[dummy].alias = "Dummy"
	sim.players[dummy].alive = true
	local targetTower = World.get(sim.world, target) :: Tower.Tower
	Units.clear(targetTower.units)
	Tower.setPlayerId(targetTower, dummy)
	sim.players[dummy].towers[target] = true
	Units.addToTower(targetTower.units, Unit.Soldier, 1, targetTower.towerType, false)

	local before = towerString(sim, source)
	local err = Game.deployForce(sim, me, source, { source, target })
	return string.format(
		"me=%d dummy=%d\nsource: %s\ntarget: %s\ndeployErr=%s",
		me,
		dummy,
		before,
		towerString(sim, target),
		tostring(err)
	)
end

-- Sahte rakip komşu kuleden benim kuleme az askerle saldırır; savunma tutar.
local function defendDummy(sim: Game.Game, simIds: { [Player]: number }): string
	local _, me = next(simIds)
	if me == nil then
		return "no player"
	end
	local data = sim.players[me]
	local source, target
	for id in data.towers do
		local tower = World.get(sim.world, id) :: Tower.Tower
		if Units.available(tower.units, Unit.Soldier) >= 4 then
			for _, n in TowerId.neighbors(id) do
				local other = World.get(sim.world, n)
				if other and other.playerId == nil then
					source, target = n, id
					break
				end
			end
		end
		if source then
			break
		end
	end
	if source == nil or target == nil then
		return "no source/target found"
	end
	local dummy = Game.playerJoined(sim, true)
	sim.players[dummy].alias = "Dummy"
	sim.players[dummy].alive = true
	local sourceTower = World.get(sim.world, source) :: Tower.Tower
	Units.clear(sourceTower.units)
	Tower.setPlayerId(sourceTower, dummy)
	sim.players[dummy].towers[source] = true
	Units.addToTower(sourceTower.units, Unit.Soldier, 2, sourceTower.towerType, false)

	local err = Game.deployForce(sim, dummy, source, { source, target })
	return string.format(
		"me=%d dummy=%d\nsource: %s\ntarget: %s\ndeployErr=%s",
		me,
		dummy,
		towerString(sim, source),
		towerString(sim, target),
		tostring(err)
	)
end

local function summary(sim: Game.Game): string
	local lines = { string.format("tick=%d towers=%d", sim.world.tick, #World.ids(sim.world)) }
	for id, data in sim.players do
		local count = 0
		for _ in data.towers do
			count += 1
		end
		table.insert(
			lines,
			string.format(
				"player %d %s alive=%s towers=%d score=%d",
				id,
				data.alias,
				tostring(data.alive),
				count,
				data.score
			)
		)
	end
	return table.concat(lines, "\n")
end

-- Köprü: iki gerçek oyuncu birbirine uzak doğduğu için, 2. oyuncuya 1. oyuncunun bölgesine
-- komşu sahipsiz bir kule (4 asker) verir. Yalnız iki oyunculu savaş testi için.
-- Suikast: sahte rakip, ilk oyuncunun kral kulesinin komşusundan krala 30 tank gönderir.
-- Ölüm oyunun kendi savaş kurallarıyla gerçekleşir (ölüm ekranı testi için).
local function assassinate(sim: Game.Game, simIds: { [Player]: number }): string
	local _, me = next(simIds)
	if me == nil then
		return "no player"
	end
	local ruler = Game.rulerTower(sim, me)
	if ruler == nil then
		return "no ruler tower"
	end
	local dummy = Game.playerJoined(sim, true)
	sim.players[dummy].alias = "Assassin"
	sim.players[dummy].alive = true
	local from = TowerId.neighbors(ruler)[1]
	if not World.contains(sim.world, from) then
		return "neighbor not generated"
	end
	local tanks = Units.new()
	Units.add(tanks, Unit.Tank, 30)
	local source = World.get(sim.world, from) :: Tower.Tower
	World.queueForces(
		sim.world,
		Tower.sendForce(source, Force.new(dummy, tanks, Path.new({ from, ruler })))
	)
	return string.format(
		"30 tanks from %s to ruler %s",
		TowerId.toString(from),
		TowerId.toString(ruler)
	)
end

-- Menzilli birim testi: ilk gerçek oyuncunun kralsız bir kulesini birimi üreten tipe çevir
-- (Shell → Artillery, Emp → Launcher, Nuke → Silo), cephane ver; menzildeki, görünen, başkasına ait
-- bir kuleyi hedef olarak öner. Gönderimi istemci sürüklemesi yapar (gerçek girdi yolu).
local RANGED_SETUP: { [string]: { unit: number, towerType: number, count: number } } = {
	Shell = { unit = Unit.Shell, towerType = TowerTypeId.Artillery, count = 3 },
	Emp = { unit = Unit.Emp, towerType = TowerTypeId.Launcher, count = 1 },
	Nuke = { unit = Unit.Nuke, towerType = TowerTypeId.Silo, count = 1 },
}

local function rangedSetup(sim: Game.Game, simIds: { [Player]: number }, name: any): string
	local setup = RANGED_SETUP[name]
	if setup == nil then
		return "usage: ranged Shell|Emp|Nuke"
	end
	local _, me = next(simIds)
	if me == nil then
		return "no player"
	end
	local data = sim.players[me]
	local range = Unit.rangedDistance(setup.unit) :: number
	local maxSquared = (range + 1) ^ 2 - 1
	local visible = Visibility.visibleTowers(sim.world, data.towers)
	local ownIds = {}
	for id in data.towers do
		table.insert(ownIds, id)
	end
	table.sort(ownIds)
	for _, source in ownIds do
		local tower = World.get(sim.world, source) :: Tower.Tower
		if not Units.hasRuler(tower.units) then
			local best, bestOwned = nil, false
			for id in visible do
				local other = World.get(sim.world, id)
				if
					other
					and other.playerId ~= me
					and id ~= source
					and TowerId.distanceSquared(source, id) <= maxSquared
					and not Units.hasRuler(other.units)
					and other.towerType ~= TowerTypeId.Bunker
					and other.towerType ~= TowerTypeId.Headquarters
				then
					local owned = other.playerId ~= nil
					if
						best == nil
						or (owned and not bestOwned)
						or (owned == bestOwned and id < best)
					then
						best, bestOwned = id, owned
					end
				end
			end
			if best ~= nil then
				tower.towerType = setup.towerType
				tower.delay = nil
				tower.supplyLine = nil
				Units.clear(tower.units)
				Units.addToTower(tower.units, setup.unit, setup.count, tower.towerType, true)
				if not bestOwned then
					-- Botlar uzaksa: hedefi askerli sahte rakibe ver (hasar görünsün).
					local dummy = Game.playerJoined(sim, true)
					sim.players[dummy].alias = "Target"
					sim.players[dummy].alive = true
					local target = World.get(sim.world, best) :: Tower.Tower
					Units.clear(target.units)
					Tower.setPlayerId(target, dummy)
					sim.players[dummy].towers[best] = true
					Units.addToTower(target.units, Unit.Soldier, 4, target.towerType, true)
					Units.addToTower(target.units, Unit.Shield, 10, target.towerType, true)
				end
				return string.format(
					"source: %s | target: %s delay=%s | range=%d distSq=%d",
					towerString(sim, source),
					towerString(sim, best),
					tostring((World.get(sim.world, best) :: Tower.Tower).delay),
					range,
					TowerId.distanceSquared(source, best)
				)
			end
		end
	end
	return "no source/target found"
end

-- Sahte rakip komşu kuleden benim kuleme füze atar (uyarı testi).
local function incomingMissile(sim: Game.Game, simIds: { [Player]: number }, name: any): string
	local setup = RANGED_SETUP[name]
	if setup == nil then
		return "usage: incoming Emp|Nuke"
	end
	local _, me = next(simIds)
	if me == nil then
		return "no player"
	end
	for id in sim.players[me].towers do
		for _, n in TowerId.neighbors(id) do
			local other = World.get(sim.world, n)
			if other and other.playerId == nil then
				local dummy = Game.playerJoined(sim, true)
				sim.players[dummy].alias = "Rocketeer"
				sim.players[dummy].alive = true
				Units.clear(other.units)
				Tower.setPlayerId(other, dummy)
				sim.players[dummy].towers[n] = true
				other.towerType = setup.towerType
				other.delay = nil
				Units.addToTower(other.units, setup.unit, setup.count, other.towerType, true)
				return "deployErr=" .. tostring(Game.deployForce(sim, dummy, n, { n, id }))
			end
		end
	end
	return "no neighbor found"
end

local function bridge(sim: Game.Game, simIds: { [Player]: number }): string
	local ids = {}
	for _, id in simIds do
		table.insert(ids, id)
	end
	table.sort(ids)
	if #ids < 2 then
		return "need two players"
	end
	local first, second = ids[1], ids[2]
	for towerId in sim.players[first].towers do
		for _, n in TowerId.neighbors(towerId) do
			local other = World.get(sim.world, n)
			if other and other.playerId == nil and #other.inboundForces == 0 then
				Units.clear(other.units)
				Tower.setPlayerId(other, second)
				sim.players[second].towers[n] = true
				Units.addToTower(other.units, Unit.Soldier, 4, other.towerType, false)
				return string.format(
					"gave %s to player %d next to player %d",
					towerString(sim, n),
					second,
					first
				)
			end
		end
	end
	return "no free neighbor tower"
end

-- Bot özeti ve ölçüm. İstatistik okunduktan sonra sıfırlanır (bir sonraki ölçüm temiz başlar).
local function botsSummary(sim: Game.Game, bots: BotRepo.BotRepo, stats: StepStats): string
	local lines = {
		string.format(
			"bots=%d towers=%d steps=%d avgMs=%.2f maxMs=%.2f replAvgMs=%.2f replMaxMs=%.2f rejected=%d",
			BotRepo.count(bots),
			#World.ids(sim.world),
			stats.steps,
			if stats.steps > 0 then stats.totalMs / stats.steps else 0,
			stats.maxMs,
			if stats.replSteps > 0 then stats.replMs / stats.replSteps else 0,
			stats.replMaxMs,
			bots.lastErrors
		),
	}
	for _, slot in bots.slots do
		local data = sim.players[slot.playerId]
		local towers = 0
		for _ in data.towers do
			towers += 1
		end
		table.insert(
			lines,
			string.format(
				"  %d %s alive=%s towers=%d score=%d",
				slot.playerId,
				data.alias,
				tostring(data.alive),
				towers,
				data.score
			)
		)
	end
	stats.steps, stats.totalMs, stats.maxMs = 0, 0, 0
	stats.replMs, stats.replMaxMs, stats.replSteps = 0, 0, 0
	return table.concat(lines, "\n")
end

function DevState.install(
	sim: Game.Game,
	simIds: { [Player]: number },
	bots: BotRepo.BotRepo,
	stats: StepStats
)
	if not RunService:IsStudio() then
		return
	end
	local remote = Instance.new("BindableFunction")
	remote.Name = "RobgameDev"
	local function handle(command: string, arg: any): string
		if command == "summary" then
			return summary(sim)
		elseif command == "attackDummy" then
			return attackDummy(sim, simIds)
		elseif command == "defendDummy" then
			return defendDummy(sim, simIds)
		elseif command == "assassinate" then
			return assassinate(sim, simIds)
		elseif command == "bridge" then
			return bridge(sim, simIds)
		elseif command == "bots" then
			return botsSummary(sim, bots, stats)
		elseif command == "setBots" then
			bots.fixedCount = if type(arg) == "number" then arg else nil
			return "fixedCount=" .. tostring(bots.fixedCount)
		elseif command == "allyMe" then
			local _, me = next(simIds)
			if me == nil or type(arg) ~= "number" then
				return "no player"
			end
			-- Oyunun kendi komutu: bot da aynı yoldan ister.
			return tostring(
				Game.command(sim, arg, { kind = "Alliance", with = me, breakAlliance = false })
			)
		elseif command == "allies" then
			local actor = sim.world.players[arg]
			if actor == nil then
				return "no player"
			end
			local ids = {}
			for id in actor.allies do
				table.insert(ids, tostring(id))
			end
			table.sort(ids)
			return table.concat(ids, ",")
		elseif command == "tower" then
			return towerString(sim, arg)
		elseif command == "hype" then
			-- Ödül anı denemesi (profile dokunmaz).
			local first = Players:GetPlayers()[1]
			local events: { [string]: any } = {
				king = { kind = "king", reward = 25 },
				combo = { kind = "combo", count = 5, reward = 10 },
				record = { kind = "record", score = 120 },
				revenge = { kind = "revenge", reward = 50 },
				chest = { kind = "streak", count = 3, reward = 60, chest = 150, day = 3 },
			}
			local event = events[arg]
			if first == nil or event == nil then
				return "usage: hype king|combo|record|revenge|chest"
			end
			require(script.Parent.AccountRewards).devNotify(first, event)
			return "sent " .. tostring(arg)
		elseif command == "incoming" then
			return incomingMissile(sim, simIds, arg)
		elseif command == "ranged" then
			return rangedSetup(sim, simIds, arg)
		elseif command == "towerDelay" then
			local tower = World.get(sim.world, arg)
			return if tower
				then towerString(sim, arg) .. " delay=" .. tostring(tower.delay)
				else "none"
		elseif command == "profile" then
			-- İlk oyuncunun profili (durum + özet). `arg` sayıysa Credits ekler (yalnız Studio testi).
			local Profiles = require(script.Parent.Profiles)
			local first = Players:GetPlayers()[1]
			if first == nil then
				return "no player"
			end
			if type(arg) == "number" then
				Profiles.mutate(first, function(p)
					p.credits += arg
				end)
			elseif arg == "toast" then
				local AccountRewards = require(script.Parent.AccountRewards)
				AccountRewards.devNotify(
					first,
					{ kind = "goal", goal = "upgrade", target = 3, reward = 50 }
				)
				AccountRewards.devNotify(first, { kind = "unlock", item = "victor_frame" })
			end
			local p = Profiles.get(first)
			local goals = {}
			if p then
				for _, g in p.daily.goals do
					table.insert(
						goals,
						string.format(
							"%s %d/%d%s",
							g.kind,
							g.progress,
							g.target,
							if g.done then "✓" else ""
						)
					)
				end
			end
			return string.format(
				"state=%s credits=%s crown=%s lives=%s best=%s captures=%s earned=%s goals=[%s]",
				tostring(Profiles.state(first)),
				tostring(p and p.credits),
				tostring(p and p.equipped.crown),
				tostring(p and p.stats.lives),
				tostring(p and p.stats.bestScore),
				tostring(p and p.stats.captures),
				tostring(p and p.daily.earned),
				table.concat(goals, ", ")
			)
		elseif command == "inv" then
			-- Envanter testi: "buy:<item>" ya da "equip:<slot>[:<item>]" (istemci komutuyla aynı yol).
			local first = Players:GetPlayers()[1]
			if first == nil or type(arg) ~= "string" then
				return "usage: inv buy:<item> | equip:<slot>[:<item>]"
			end
			local parts = string.split(arg, ":")
			local InventoryService = require(script.Parent.InventoryService)
			if parts[1] == "grant" then
				-- Yalnız Studio: ürünü profile doğrudan ver (Game Pass / kilit açma testi).
				local Profiles = require(script.Parent.Profiles)
				return tostring(Profiles.mutate(first, function(p)
					p.owned[parts[2]] = true
				end))
			elseif parts[1] == "buy" then
				return tostring(InventoryService.devRun(first, "BuyItem", { item = parts[2] }))
			elseif parts[1] == "equip" then
				return tostring(
					InventoryService.devRun(
						first,
						"EquipItem",
						{ slot = parts[2], item = parts[3] }
					)
				)
			end
			return "unknown inv action"
		elseif command == "activity" then
			-- Aktif oynama testi: oyuncu komut vermiş gibi işaretle.
			local first = Players:GetPlayers()[1]
			if first == nil then
				return "no player"
			end
			require(script.Parent.AccountRewards).noteActivity(first)
			return "ok"
		elseif command == "buyCredits" then
			-- Credits paketi teslim testi: arg "purchaseId:paketSırası" (aynı kimlik ikinci kez verilmez).
			local first = Players:GetPlayers()[1]
			if first == nil or type(arg) ~= "string" then
				return "usage: buyCredits <purchaseId>:<packIndex>"
			end
			local parts = string.split(arg, ":")
			return require(script.Parent.PurchaseService).devReceipt(
				first,
				parts[1],
				tonumber(parts[2]) or 1
			)
		elseif command == "worlds" then
			return require(script.Parent.WorldService).devFake(
				if type(arg) == "number" then arg else 2
			)
		elseif command == "fastForward" then
			-- Yalnız Studio: simülasyonu `arg` tick ileri sar (4 tick = 1 sn; 45 dk = 10800).
			-- Botlar oynar; ana döngü beklemez. Büyük değerleri parça parça çağır (sunucu donar).
			-- Arka planda çalışır: her 20 tickte bir bekler (script zaman aşımı). Kalan `FastForwardLeft`.
			local ticks = if type(arg) == "number" then math.clamp(math.floor(arg), 1, 20000) else 0
			remote:SetAttribute("FastForwardLeft", ticks)
			task.spawn(function()
				for i = 1, ticks do
					local realPlayers = 0
					for _ in simIds do
						realPlayers += 1
					end
					BotRepo.step(bots, sim, realPlayers)
					if i % 20 == 0 then
						remote:SetAttribute("FastForwardLeft", ticks - i)
						task.wait()
					end
				end
				remote:SetAttribute("FastForwardLeft", 0)
			end)
			return string.format("started %d ticks from tick=%d", ticks, sim.world.tick)
		elseif command == "aggression" then
			return tostring(bots.aggression) .. " fixed=" .. tostring(bots.fixedCount)
		elseif command == "partyRoom" then
			-- Studio'da ışınlama yok (Roblox belgesi): oda ayarını doğrudan uygula.
			local first = Players:GetPlayers()[1]
			return require(script.Parent.PartyService).devSimulateRoom(
				if type(arg) == "number" or type(arg) == "string" then arg else -1,
				if first then first.UserId else 0
			)
		end
		return "unknown command"
	end
	remote.OnInvoke = handle
	-- Studio MCP sandbox'ı BindableFunction çağıramıyor (Network yetkisi); aynı komutlar özellikle:
	-- `RobgameDev:SetAttribute("Command", "defendDummy")` → sonuç `Result` özelliğinde.
	-- İsteğe bağlı argüman `Arg` özelliğinden okunur.
	remote:GetAttributeChangedSignal("Command"):Connect(function()
		local command = remote:GetAttribute("Command")
		if type(command) ~= "string" or command == "" then
			return
		end
		local ok, result = pcall(handle, command, remote:GetAttribute("Arg"))
		remote:SetAttribute(
			"Result",
			if ok then tostring(result) else "error: " .. tostring(result)
		)
		remote:SetAttribute("Command", "")
	end)
	remote.Parent = ServerStorage
end

return DevState
