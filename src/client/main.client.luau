--!strict
-- İstemci giriş noktası: doğma isteği gönderir, sunucu durumunu çizer, girdiyi (fare, dokunma,
-- klavye) komutlara çevirir, RTS kamerayı her karede günceller.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AccountView = require(script.Parent.AccountView)
local AlertOverlay = require(script.Parent.AlertOverlay)
local Ambience = require(script.Parent.Ambience)
local Audio = require(script.Parent.Audio)
local Camera = require(script.Parent.Camera)
local DeathScreen = require(script.Parent.DeathScreen)
local Fog = require(script.Parent.Fog)
local ForceView = require(script.Parent.ForceView)
local AttackArrows = require(script.Parent.AttackArrows)
local GoalsScreen = require(script.Parent.GoalsScreen)
local HelpScreen = require(script.Parent.HelpScreen)
local Icons = require(script.Parent.Icons)
local Input = require(script.Parent.Input)
local LoadingScreen = require(script.Parent.LoadingScreen)
local Leaderboard = require(script.Parent.Leaderboard)
local LockerScreen = require(script.Parent.LockerScreen)
local Nav = require(script.Parent.Nav)
local PartyMenu = require(script.Parent.PartyMenu)
local QuickBar = require(script.Parent.QuickBar)
local RankingsScreen = require(script.Parent.RankingsScreen)
local Settings = require(script.Parent.Settings)
local Strings = require(script.Parent.Strings)
local SoloMenu = require(script.Parent.SoloMenu)
local StartScreen = require(script.Parent.StartScreen)
local StoreScreen = require(script.Parent.StoreScreen)
local Territory = require(script.Parent.Territory)
local TopBar = require(script.Parent.TopBar)
local Tutorial = require(script.Parent.Tutorial)
local TowerPanel = require(script.Parent.TowerPanel)
local WorldView = require(script.Parent.WorldView)

local Rewards = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Account"):WaitForChild("Rewards")
)
local TowerId =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"):WaitForChild("TowerId"))
local Alerts =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"):WaitForChild("Alerts"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local commandRemote = remotes:WaitForChild("Command") :: RemoteEvent
local stateRemote = remotes:WaitForChild("State") :: RemoteEvent

-- `Command::Spawn`: takma adı sunucu Roblox görünen adından alır.
local function spawn()
	commandRemote:FireServer({ kind = "Spawn" })
end

-- Arayüz yatay tasarlandı (kaydırmalı listeler telefonda da taşmaz); dik ekran desteklenmez.
local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor

-- Müzik yükleme ekranında başlar ve ana menüde sürer (tercih gelene kadar sessiz, bkz. Audio).
Audio.music("menu")
LoadingScreen.show()
-- Işınlama (solo/parti sunucusu) sırasında aynı görünümlü durağan ekran (yalnız yayında çalışır).
LoadingScreen.setupTeleport()

DeathScreen.init(spawn, {
	store = StoreScreen.open,
	friends = PartyMenu.open,
	rankings = RankingsScreen.open,
	nextGoal = function(): string?
		local profile = AccountView.profile()
		if profile == nil then
			return nil
		end
		local goal = Rewards.nextGoal(profile :: any)
		if goal == nil then
			return nil
		end
		local stats = profile.stats :: any
		local name = if goal.id == "kings_1"
			then Strings.achievementFirstKing
			else string.format(Strings.achievementText[goal.stat] or "%d", goal.target)
		return string.format(
			Strings.nextGoal,
			name,
			stats[goal.stat] or 0,
			goal.target,
			goal.reward
		)
	end,
})
WorldView.setChangedHook(function(id: number?)
	if id then
		Territory.markDirty(id)
	else
		Territory.markAllDirty()
	end
end)
HelpScreen.init()
Settings.init(HelpScreen.open, function()
	Tutorial.restart()
end)
Ambience.init()

-- Menü arkası canlı dünya: kuleler geldi ve modeller indi. Modeller yoksa anahtar görsel kalır.
local MIN_TOWER_MESHES = 20
local worldAssetsReady = false
local worldReceived = false

local function tryShowLiveWorld()
	if worldAssetsReady and worldReceived then
		StartScreen.showLiveWorld()
	end
end

-- Harita görsellerini giriş ekranındayken indir (Roblox görseli ilk kullanımda indirir; oyun
-- başında çimen, bulut ve oklar geç beliriyordu). Kule/birlik modelleri ReplicatedStorage'da.
-- Yükleme ekranı: her şey inene kadar oyun görünmez, kaplamalar gözün önünde teker teker gelmez.
task.spawn(function()
	-- Logo ve arka plan önce: yoksa uzun listenin arkasında sıraya girip geç beliriyordu.
	LoadingScreen.preload({ Icons.logo, Icons.loadingArt })
	local list: { any } = {}
	for _, id in Icons.all() do
		table.insert(list, id)
	end
	for _, id in Fog.ASSETS do
		table.insert(list, id)
	end
	for _, id in Input.ASSETS do
		table.insert(list, id)
	end
	table.insert(list, WorldView.ROAD_TEXTURE)
	table.insert(list, WorldView.PAD_TEXTURE)
	for _, v in game:GetService("MaterialService"):GetChildren() do
		table.insert(list, v)
	end
	table.insert(list, game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui"))
	for _, name in { "TowerMeshes", "UnitMeshes", "PropMeshes", "ProjectileMeshes" } do
		local folder = ReplicatedStorage:WaitForChild(name, 20)
		if folder then
			for _, child in folder:GetChildren() do
				table.insert(list, child)
			end
		end
	end
	LoadingScreen.load(list)
	LoadingScreen.hide()
	-- Sunucu modelleri alamadıysa (ağ) klasör eksik kalır: canlı dünya yerine anahtar görsel.
	local meshes = ReplicatedStorage:FindFirstChild("TowerMeshes")
	worldAssetsReady = meshes ~= nil and #meshes:GetChildren() >= MIN_TOWER_MESHES
	tryShowLiveWorld()
end)

-- Parti paneli (kodiak "Play with friends"): mesajlar aynı komut kanalından gider.
AccountView.init(function(message)
	commandRemote:FireServer(message)
end)
StoreScreen.init()
GoalsScreen.init()
LockerScreen.init(StoreScreen.open)
RankingsScreen.init(function(message)
	commandRemote:FireServer(message)
end)
Tutorial.configure(function(): boolean
	local profile = AccountView.profile()
	return profile ~= nil and profile.tutorialDone
end, function()
	AccountView.setTutorialDone(true)
end)
PartyMenu.init(function(message)
	commandRemote:FireServer(message)
end)
Nav.init({
	goals = GoalsScreen.open,
	store = StoreScreen.open,
	locker = LockerScreen.open,
	friends = PartyMenu.open,
	settings = Settings.open,
})
Leaderboard.init()
-- Üst sıra ana ekranda yok: ana ekranın kendi düğmeleri var, canlı dünya arkadan görünür.
Nav.setVisible(false)

-- Hayatta mı (kamera ve girdi için). Hello → doğdu; Delta.alive == false → öldü.
local alive = false
-- Menü arkasında bot izleniyor (doğunca biter).
local spectating = false

local function setSpectating(value: boolean)
	spectating = value
	Audio.setWorldMuted(value)
	Camera.setMenu(value)
	Input.setEnabled(not value)
end

stateRemote.OnClientEvent:Connect(function(message: any)
	if type(message) ~= "table" then
		return
	end
	if message.kind == "Spectate" then
		if alive then
			return
		end
		Territory.clear()
		Fog.clear()
		WorldView.reset(message.you)
		ForceView.clear()
		ForceView.setServerTick(message.tick)
		setSpectating(true)
	elseif message.kind == "Hello" then
		print(string.format("[robgame] hello: you are sim player %d", message.you))
		setSpectating(false)
		Nav.setVisible(true)
		Territory.clear()
		Fog.clear()
		WorldView.reset(message.you)
		ForceView.clear()
		DeathScreen.hide()
		StartScreen.hide()
		Audio.music("game")
		Audio.play("spawn")
		Input.reset()
		AlertOverlay.reset()
		alive = true
		TopBar.setVisible(true)
		QuickBar.setVisible(true)
		AttackArrows.setVisible(true)
		Tutorial.setAlive(true)
		Leaderboard.setVisible(true)
		ForceView.setServerTick(message.tick)
	elseif message.kind == "SpawnFailed" then
		DeathScreen.spawnFailed(
			if type(message.reason) == "string" then message.reason else "SPAWN_FAILED"
		)
	elseif message.kind == "Profile" then
		AccountView.applyProfile(message)
	elseif message.kind == "Reward" then
		AccountView.reward(message)
	elseif message.kind == "Cosmetics" then
		AccountView.applyCosmetics(message)
	elseif message.kind == "InventoryResult" then
		AccountView.inventoryResult(message)
	elseif message.kind == "PurchaseResult" then
		AccountView.purchaseResult(message)
	elseif message.kind == "Liveboard" then
		Leaderboard.apply(message)
	elseif message.kind == "Rankings" then
		RankingsScreen.apply(message)
	elseif message.kind == "Worlds" then
		StartScreen.setWorlds(message.rows)
	elseif message.kind == "PartyInfo" then
		PartyMenu.info(message)
	elseif message.kind == "PartyStatus" then
		PartyMenu.status(message)
	elseif message.kind == "Delta" then
		ForceView.setServerTick(message.tick)
		WorldView.applyPlayers(message.players)
		WorldView.applyTowers(message.towers)
		WorldView.removeTowers(message.hidden)
		WorldView.removeTowers(message.destroyed)
		ForceView.apply(message.forces, message.removedForces)
		if spectating and not worldReceived and #message.towers > 0 then
			worldReceived = true
			tryShowLiveWorld()
		end
		if message.alerts ~= nil then
			TopBar.applyAlerts(message.alerts)
			Audio.setHeartbeat(Alerts.has(message.alerts, Alerts.RulerUnderAttack))
			Tutorial.applyAlerts(message.alerts)
			AlertOverlay.apply(message.alerts)
		end
		if message.towerCounts ~= nil then
			WorldView.applyTowerCounts(message.towerCounts)
		end
		if message.allies ~= nil and message.incoming ~= nil then
			WorldView.applyAlliances(message.allies, message.incoming)
		end
		if message.alive == false then
			print("[robgame] you died")
			Audio.play("death")
			alive = false
			Input.reset()
			AlertOverlay.reset()
			TopBar.setVisible(false)
			QuickBar.setVisible(false)
			AttackArrows.setVisible(false)
			Audio.setHeartbeat(false)
			Tutorial.setAlive(false)
			Leaderboard.setVisible(false)
			ForceView.clear()
			DeathScreen.show(message.death)
		end
	end
end)

-- Oyun başı: giriş ekranı; "Play" doğuş isteğini aynı bekleme/yeniden deneme akışından gönderir.
StartScreen.show({
	play = DeathScreen.requestSpawn,
	solo = SoloMenu.open,
	joinWorld = PartyMenu.joinWorld,
	friends = PartyMenu.open,
	help = HelpScreen.open,
	store = StoreScreen.open,
	locker = LockerScreen.open,
	goals = GoalsScreen.open,
	rankings = RankingsScreen.open,
	settings = Settings.open,
})

if PartyMenu.shouldAutoPlay() then
	StartScreen.autoPlay()
end

Input.start({
	-- `Command::DeployForce { tower_id, path }`
	deployForce = function(towerId: number, path: { number })
		Audio.play("deploy")
		commandRemote:FireServer({ kind = "DeployForce", towerId = towerId, path = path })
	end,
	-- `Command::SetSupplyLine { tower_id, path }` (path nil → kaldır)
	setSupplyLine = function(towerId: number, path: { number }?)
		commandRemote:FireServer({ kind = "SetSupplyLine", towerId = towerId, path = path })
	end,
	jumpToAlert = function()
		local towerId = AlertOverlay.topTower()
		if towerId ~= nil then
			local x, y = TowerId.integerPosition(towerId)
			Camera.panTo(Vector2.new(x, y))
		end
	end,
})
QuickBar.init()
AttackArrows.init(function(towerId: number)
	local x, y = TowerId.integerPosition(towerId)
	Camera.panTo(Vector2.new(x, y))
end)
AttackArrows.setVisible(false)
ForceView.setMissileHandler(AlertOverlay.setMissiles)

-- Uyarıya dokununca kamera o kuleye gider (`KiometUiEvent::PanTo`).
AlertOverlay.init(function(towerId: number)
	local x, y = TowerId.integerPosition(towerId)
	Camera.panTo(Vector2.new(x, y))
end)

TowerPanel.init({
	-- `Command::Upgrade { tower_id, tower_type }`
	upgrade = function(towerId: number, towerType: number)
		Audio.play("upgrade")
		commandRemote:FireServer({ kind = "Upgrade", towerId = towerId, towerType = towerType })
	end,
	-- `Command::Alliance { with, break_alliance }`
	alliance = function(with: number, breakAlliance: boolean)
		commandRemote:FireServer({ kind = "Alliance", with = with, breakAlliance = breakAlliance })
	end,
})

TopBar.init({
	panToRuler = Camera.panToRuler,
	zoom = function(factor: number)
		local center = Camera.debugState()
		Camera.multiplyZoom(center, factor)
	end,
	clearSupplyLines = Input.clearSupplyLines,
})
Tutorial.init()

-- Roblox'un varsayılan kamera betiği (PlayerModule) her kare kamerayı günceller.
-- Onun adımından sonra çalışıp tipi ve konumu her karede yeniden ayarlıyoruz.
RunService:BindToRenderStep(
	"RobgameCamera",
	Enum.RenderPriority.Camera.Value + 1,
	function(dt: number)
		Input.update()
		Camera.update(dt, alive)
		TowerPanel.update(not alive or Input.isDragging())
		ForceView.render()
		TopBar.update(dt)
		QuickBar.update(dt)
		if alive then
			AttackArrows.update(dt)
		end
		Ambience.update()
		Tutorial.update(dt)
		Territory.update(dt, Camera.zoom())
		Fog.update(dt)
	end
)

print("[robgame] client started")
