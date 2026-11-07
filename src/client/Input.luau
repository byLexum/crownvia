--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/game.rs (peek_mouse, get_closest)
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: client/src/broker/client_broker.rs (touch, wheel) (tag 0.1.1)

-- Girdi: fare, dokunma ve klavye. Kiomet'te karşılığı client/src/game.rs ve path.rs.
--   - Bir kuleye tıkla/dokun: seç / seçimi kaldır (rakip kulesi de seçilir: panel, ittifak).
--     Boşluğa tıkla: seçimi kaldır.
--   - Seçili OLMAYAN kendi kulenden sürükle: `DeployForce`.
--   - Seçili kuleden sürükle (kule hareketli birim üretiyorsa): `SetSupplyLine`.
--     Aynı hattı tekrar çizmek hattı kaldırır.
--   - Shift+R: seçili kulenin hattını kaldır; seçim yoksa basılı tutulduğu sürece tick başına
--     bir hattı kaldır. Dokunmatikte aynı işi Hud düğmesi yapar.
--   - Kaydırma: sağ tuşla sürükle (kaynak), tekerlek: imleç etrafında yakınlaştır (kaynak),
--     iki parmak: kaydır + çimdikle yakınlaştır (kodiak), WASD/oklar, Q/E, H (Camera).
--   - Roblox uyarlaması (kural değil, kontrol): kendi kulen olmayan yerden tek parmak/sol tuşla
--     sürüklemek haritayı kaydırır. Kaynakta sol sürükleme her zaman en yakın kuleden yol çizer;
--     başkasının kulesinden çizilen yol sunucuda zaten reddedilir. İkinci parmak gelince devam
--     eden kule sürüklemesi komut göndermeden iptal edilir (kodiak sol tuşu bırakıp gönderirdi).
--   - Kontrol kolaylığı (kaynakta yok, kural değil): 1-6 türe göre kuleler arasında gez, Shift+1-6
--     ya da Shift+tık grup seçer, gruptan sürükleme her kuleden ayrı `DeployForce` gönderir
--     (kralın olduğu kule hariç), X grubu bırakır, Boşluk en acil uyarıya gider.
-- Kule seçimi kaynaktaki gibi en yakın bilinen kuleye göre (`get_closest`), kutuya isabet gerekmez.
-- Yol istemcide bilinen kulelerle bulunur (Sim/Pathfinding); sunucu yeniden doğrular.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local Path = require(Sim.Path)
local Pathfinding = require(Sim.Pathfinding)
local Ticks = require(Sim.Ticks)
local TowerId = require(Sim.TowerId)
local TowerType = require(Sim.TowerType)
local Unit = require(Sim.Unit)

local Camera = require(script.Parent.Camera)
local GroundRing = require(script.Parent.GroundRing)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

export type Commands = {
	deployForce: (towerId: number, path: { number }) -> (),
	setSupplyLine: (towerId: number, path: { number }?) -> (),
	jumpToAlert: () -> (),
}

-- Hızlı seçim türleri: kulenin ürettiği birime göre (`TowerType.unitGeneration`).
export type Group = { name: string, units: { number } }

type Record = WorldView.TowerRecord

local Input = {}

Input.GROUPS = {
	{ name = "Soldiers", units = { Unit.Soldier } },
	{ name = "Tanks", units = { Unit.Tank } },
	{ name = "Aircraft", units = { Unit.Fighter, Unit.Chopper, Unit.Bomber } },
	{ name = "Artillery", units = { Unit.Shell } },
	{ name = "EMP", units = { Unit.Emp } },
	{ name = "Nukes", units = { Unit.Nuke } },
} :: { Group }

local GROUP_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
}
-- Komut kovası saniyede 10 (CommandRemote): grup bunu aşmasın.
local GROUP_MAX = 10
local SIMILAR_MAX = 40
local GROUP_SEND_GAP = 0.12

local DEPLOY_COLOR = Theme.colors.gold
local SUPPLY_COLOR = Color3.fromRGB(90, 230, 130)
-- game.rs `RULER_DRAG_DELAY`: kralı tehlikeli yoldan göndermek için hedefte bekleme süresi (sn).
local RULER_DRAG_DELAY = 1.2
-- Bu kadar pikselden fazla hareket sürükleme sayılır.
local DRAG_THRESHOLD = 8
-- kodiak `touch`: `delta = 0.03 * (önceki - şimdiki parmak aralığı)` → `raw_zoom`.
local PINCH_ZOOM_PER_PIXEL = 0.03
-- kodiak `wheel`: bir tekerlek adımı `raw_zoom(0.5)`.
local WHEEL_ZOOM_STEP = 0.5

-- Kendi kulesinden başlayan sürükleme (yol çizimi).
type Pointer = {
	-- Dokunmaysa parmağın InputObject'i; fareyse nil.
	touch: InputObject?,
	source: number,
	start: Vector2,
	dragging: boolean,
	supply: boolean,
	maxEdgeDistance: number?,
	-- Önizleme parçaları (yol segmentleri + kral bekleme işareti).
	preview: { Part },
	marker: Part?,
	-- Hedef kulenin altında yer halkası (seçim halkasıyla aynı dil).
	ring: GroundRing.Ring?,
	-- Önizlenen hedef ve onun için hesaplanan yol (hedef değişince yeniden hesaplanır).
	previewTarget: number?,
	previewPath: { number }?,
	previewViable: boolean,
	previewPerilous: boolean,
	lastScreen: Vector2?,
	-- İmlecin üzerinde durduğu kule ve oraya geliş zamanı (game.rs `Drag::current`).
	hover: number?,
	hoverStart: number,
}

-- Kendi kulesi olmayan yerden başlayan basış: dokunup bırakma ya da haritayı kaydırma.
type Press = {
	touch: InputObject?,
	start: Vector2,
	panning: boolean,
}

-- İki parmak: kaydır + çimdik.
type Gesture = {
	a: InputObject,
	b: InputObject,
	distance: number,
}

local selected: number? = nil
local pointer: Pointer? = nil
local press: Press? = nil
local gesture: Gesture? = nil
local rightPanning = false
-- Arayüze değmeyen, basılı parmaklar (basış sırasıyla).
local touches: { InputObject } = {}
local commandsRef: Commands? = nil
-- Grup seçimi: kule → yer halkası.
local group: { [number]: GroundRing.Ring } = {}
local hoverRing: GroundRing.Ring? = nil
-- Menü arkasında izlerken dünya dokunmaya kapalı.
local enabled = true

local function isShift(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function screenOf(input: InputObject): Vector2
	return Vector2.new(input.Position.X, input.Position.Y)
end

-- `InputObject.Position` GUI payı (üst çubuk) düşülmüş koordinattır; eşi `ScreenPointToRay`
-- (create.roblox.com/docs: InputObject.Position, Camera.ScreenPointToRay).
-- Ekran noktasına en yakın bilinen kule.
local function towerAt(screen: Vector2): number?
	local point = Camera.screenToWorld(screen)
	if point == nil then
		return nil
	end
	return WorldView.closest(point)
end

-- Kuledeki hareketli birimler var mı ve menzilleri (`force_units().max_edge_distance()`).
local function strengthEdge(record: Record): (boolean, number?)
	for unit = 0, Unit.COUNT - 1 do
		if record.u[unit + 1] > 0 and Unit.isMobile(unit, record.t) then
			return true, Unit.rangedDistance(unit)
		end
	end
	return false, nil
end

-- `Tower::generates_mobile_units` (kral varken Shield dışı üretim yok).
local function generatesMobileUnits(record: Record): boolean
	local hasRuler = record.u[Unit.Ruler + 1] > 0
	for unit = 0, Unit.COUNT - 1 do
		if Unit.isMobile(unit, record.t) and not (hasRuler and unit ~= Unit.Shield) then
			if TowerType.unitGeneration(record.t, unit) ~= nil then
				return true
			end
		end
	end
	return false
end

-- game.rs: `max_edge_distance = strength_edge.map_or(tower_edge, |e| e.min(tower_edge))`.
-- `Option::min`: None en küçüktür.
local function dragLimits(record: Record): (boolean, number?, boolean)
	local hasStrength, unitsEdge = strengthEdge(record)
	local towerEdge = TowerType.rangedDistance(record.t)
	local maxEdge: number?
	if not hasStrength then
		maxEdge = towerEdge
	elseif unitsEdge == nil or towerEdge == nil then
		maxEdge = nil
	else
		maxEdge = math.min(unitsEdge, towerEdge)
	end
	local shorter = maxEdge ~= towerEdge
	return hasStrength, maxEdge, shorter
end

local function sameList(a: { number }?, b: { number }): boolean
	if a == nil or #a ~= #b then
		return false
	end
	for i, id in b do
		if a[i] ~= id then
			return false
		end
	end
	return true
end

local function setSelected(id: number?)
	selected = id
	WorldView.setSelected(id)
end

local function groundRing(name: string, color: Color3): GroundRing.Ring
	return GroundRing.new(name, 11, color, WorldView.towersFolder().Parent :: Instance)
end

local function clearGroup()
	for _, ring in group do
		ring.destroy()
	end
	table.clear(group)
end

local function addToGroup(id: number)
	if (group[id] :: GroundRing.Ring?) == nil then
		local ring = groundRing("GroupRing", DEPLOY_COLOR)
		local at = WorldView.position(id)
		ring.setCFrame(CFrame.new(at.X, 0.66, at.Z))
		group[id] = ring
	end
end

local function groupSize(): number
	local count = 0
	for _ in group do
		count += 1
	end
	return count
end

local function producesGroup(record: Record, index: number): boolean
	for _, unit in Input.GROUPS[index].units do
		if TowerType.unitGeneration(record.t, unit) ~= nil then
			return true
		end
	end
	return false
end

-- Bu türü üreten kendi kuleleri (id sırasıyla).
function Input.groupTowers(index: number): { number }
	local me = WorldView.me()
	local list = {}
	for id, record in WorldView.records() do
		if record.o == me and producesGroup(record, index) then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

-- T basılıyken seçili kuleyle aynı türdeki kuleler işaretlenir (game.rs `show_similar_towers`).
local similar: { GroundRing.Ring } = {}

local function hideSimilar()
	for _, ring in similar do
		ring.destroy()
	end
	table.clear(similar)
end

local function showSimilar()
	hideSimilar()
	local record = if selected then WorldView.record(selected) else nil
	if record == nil then
		return
	end
	for i, id in WorldView.towersOfType(record.t) do
		if i > SIMILAR_MAX then
			break
		end
		local ring = groundRing("SimilarRing", Theme.colors.text)
		local at = WorldView.position(id)
		ring.setCFrame(CFrame.new(at.X, 0.67, at.Z))
		table.insert(similar, ring)
	end
end

-- Türün kuleleri arasında sıradakine geç.
function Input.cycleGroup(index: number)
	local list = Input.groupTowers(index)
	if #list == 0 then
		return
	end
	clearGroup()
	local nextId = list[1]
	for _, id in list do
		if selected ~= nil and id > selected then
			nextId = id
			break
		end
	end
	setSelected(nextId)
	local x, y = TowerId.integerPosition(nextId)
	Camera.panTo(Vector2.new(x, y))
end

-- Türün kulelerini (en fazla GROUP_MAX) grup seç.
function Input.selectGroup(index: number)
	clearGroup()
	setSelected(nil)
	for i, id in Input.groupTowers(index) do
		if i > GROUP_MAX then
			break
		end
		addToGroup(id)
	end
end

-- game.rs `is_perilous`: başka oyuncunun ya da sahipsiz kule.
local function isPerilous(id: number, me: number): boolean
	local record = WorldView.record(id)
	return record ~= nil and record.o ~= me
end

-- Kral taşıyan birlik tehlikeli bir yoldan mı gidecek (bekleme gerekiyor mu).
local function needsRulerDelay(current: Pointer, path: { number }?): boolean
	local me = WorldView.me()
	local record = WorldView.record(current.source)
	if
		me == nil
		or record == nil
		or current.supply
		or record.u[Unit.Ruler + 1] == 0
		or path == nil
	then
		return false
	end
	for _, id in path do
		if isPerilous(id, me) then
			return true
		end
	end
	return false
end

local function findPath(current: Pointer, target: number): { number }?
	local me = WorldView.me()
	if me == nil then
		return nil
	end
	return Pathfinding.findBestPath(
		WorldView.pathView(),
		current.source,
		target,
		current.maxEdgeDistance,
		me,
		function(_id)
			return true
		end
	)
end

local INVALID_COLOR = Theme.colors.alert
local MARKER_COLOR = Theme.colors.gold

-- Ok başı dokusu (kalın beyaz chevron + lacivert kontur, ucu görselin üstünde; `Color` ile boyanır,
-- F ailesi 2026-11-06, kaynak `dist/ui_f/out/chevron.png`).
-- Studio'da ölçüldü: Beam'de görselin dikey ekseni boy boyunca uzanır ve görselin üstü
-- Attachment0'a bakar; pozitif TextureSpeed dokuyu Attachment1'e doğru kaydırır.
local CHEVRON_TEXTURE = "rbxassetid://101512903999693"
Input.ASSETS = { CHEVRON_TEXTURE }

-- Önizleme parçası: görünmez taşıyıcı + yol boyunca hedefe doğru akan ok başları (Beam).
-- Kaynakta (road.rs `draw_path`) yol parçası çizgisi; bizde aynı yol, daha okunur gösterim.
local function previewPart(current: Pointer, index: number): Part
	local existing: Part? = current.preview[index]
	if existing ~= nil then
		return existing
	end
	local part = Instance.new("Part")
	part.Name = "DragPreview"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	local a0 = Instance.new("Attachment")
	a0.Name = "From"
	a0.Parent = part
	local a1 = Instance.new("Attachment")
	a1.Name = "To"
	a1.Parent = part
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Texture = CHEVRON_TEXTURE
	beam.TextureMode = Enum.TextureMode.Static
	beam.TextureLength = 2.2
	-- Negatif: akış Attachment0'a (hedefe) doğru.
	beam.TextureSpeed = -1.6
	beam.Width0 = 2
	beam.Width1 = 2
	beam.FaceCamera = true
	beam.LightEmission = 0
	beam.LightInfluence = 0
	beam.ZOffset = GroundRing.Z_OFFSET
	beam.Parent = part
	part.Parent = WorldView.towersFolder().Parent
	current.preview[index] = part
	return part
end

local function targetRing(current: Pointer): GroundRing.Ring
	local existing = current.ring
	if existing then
		return existing
	end
	local ring =
		GroundRing.new("DragTarget", 10, DEPLOY_COLOR, WorldView.towersFolder().Parent :: Instance)
	current.ring = ring
	return ring
end

local function clearPreview(current: Pointer)
	for _, part in current.preview do
		part:Destroy()
	end
	table.clear(current.preview)
	local ring = current.ring
	if ring then
		ring.destroy()
		current.ring = nil
	end
	local marker = current.marker
	if marker then
		marker:Destroy()
		current.marker = nil
	end
end

-- Parçanın "olası değil" olup olmadığı (road.rs `draw_path`): `MAX_PATH_ROADS`'u aşan ya da kenarı
-- `max_edge_distance`'tan (yoksa `MAX_ROAD_LENGTH`) uzun olan parça ve sonrası.
-- Kaynakta indeks 0 tabanlı: `i >= max_edges` → bizde (i - 1) >= MAX_PATH_ROADS.
local function edgeInvalid(current: Pointer, path: { number }, i: number): boolean
	local maxEdge = current.maxEdgeDistance or TowerId.MAX_ROAD_LENGTH
	return i - 1 >= Path.MAX_PATH_ROADS or TowerId.distance(path[i - 1], path[i]) > maxEdge
end

-- game.rs sürükleme önizlemesi: `find_best_incomplete_path(start, current)` (hedefe yol yoksa
-- ulaşılabilen en yakın kuleye) + hedefin kendisi.
local function computePreviewPath(current: Pointer, target: number)
	local me = WorldView.me()
	current.previewTarget = target
	current.previewPath = nil
	current.previewViable = false
	current.previewPerilous = false
	if me == nil then
		return
	end
	local ids = Pathfinding.findBestIncompletePath(
		WorldView.pathView(),
		current.source,
		target,
		current.maxEdgeDistance,
		me,
		function(_id)
			return true
		end
	)
	local path = {}
	for _, id in ids do
		if id ~= target then
			table.insert(path, id)
		end
	end
	table.insert(path, target)
	local viable = #path >= 2
	for i = 2, #path do
		if edgeInvalid(current, path, i) then
			viable = false
		end
	end
	local perilous = false
	for _, id in path do
		if isPerilous(id, me) then
			perilous = true
		end
	end
	current.previewPath = path
	current.previewViable = viable
	current.previewPerilous = perilous
end

local function updatePreview(current: Pointer, screen: Vector2)
	current.lastScreen = screen
	local hovered = towerAt(screen)
	if hovered ~= current.hover then
		current.hover = hovered
		current.hoverStart = os.clock()
	end
	if hovered == nil or hovered == current.source then
		clearPreview(current)
		current.previewTarget = nil
		return
	end
	if current.previewTarget ~= hovered then
		computePreviewPath(current, hovered)
	end
	local path = current.previewPath
	if path == nil then
		clearPreview(current)
		return
	end

	local baseColor = if current.supply then SUPPLY_COLOR else DEPLOY_COLOR
	local lift = Vector3.new(0, 1, 0)
	local hypothetical = false
	local count = 0
	for i = 2, #path do
		if edgeInvalid(current, path, i) then
			hypothetical = true
		end
		local from = WorldView.position(path[i - 1]) + lift
		local to = WorldView.position(path[i]) + lift
		count += 1
		local part = previewPart(current, count)
		local length = math.max((to - from).Magnitude, 0.1)
		part.Size = Vector3.new(0.2, 0.2, length)
		part.CFrame = CFrame.lookAt((from + to) / 2, to)
		local a0 = part:FindFirstChild("From") :: Attachment
		local a1 = part:FindFirstChild("To") :: Attachment
		-- "From" adlı Attachment0 hedef ucunda: ok başları hedefi gösterir.
		a0.Position = Vector3.new(0, 0, -length / 2)
		a1.Position = Vector3.new(0, 0, length / 2)
		local beam = part:FindFirstChildOfClass("Beam") :: Beam
		beam.Color = ColorSequence.new(if hypothetical then INVALID_COLOR else baseColor)
		beam.Transparency = NumberSequence.new(if hypothetical then 0.45 else 0.05)
	end
	-- Hedef halkası: geçerli yolda gönderim rengi, değilse kızıl.
	local ring = targetRing(current)
	local at = WorldView.position(hovered)
	ring.setCFrame(CFrame.new(at.X, 0.68, at.Z))
	ring.setColor(if hypothetical or not current.previewViable then INVALID_COLOR else baseColor)
	for i = #current.preview, count + 1, -1 do
		current.preview[i]:Destroy()
		current.preview[i] = nil
	end

	-- Kral tehlikeli yoldaysa hedefte bekleme işareti (game.rs: `progress`, hazır olunca
	-- belirginleşir). `Input.update` ile her karede ilerler, fare hareketine bağlı değil.
	local record = WorldView.record(current.source)
	local showMarker = current.previewViable
		and current.previewPerilous
		and not current.supply
		and record ~= nil
		and record.u[Unit.Ruler + 1] > 0
	if showMarker then
		local marker = current.marker
		if marker == nil then
			local m = Instance.new("Part")
			m.Name = "RulerHold"
			m.Shape = Enum.PartType.Ball
			m.Anchored = true
			m.CanCollide = false
			m.CanQuery = false
			m.Material = Enum.Material.Neon
			m.Color = MARKER_COLOR
			m.Parent = WorldView.towersFolder().Parent
			current.marker = m
			marker = m
		end
		local progress = (os.clock() - current.hoverStart) / RULER_DRAG_DELAY
		local ready = progress >= 1
		local fade = if ready then 1 else progress * 0.6
		local m = marker :: Part
		m.Transparency = 1 - fade
		local size = if ready then 3 else 2
		m.Size = Vector3.new(size, size, size)
		m.Position = WorldView.position(hovered) + Vector3.new(0, 4, 0)
	else
		local marker = current.marker
		if marker then
			marker:Destroy()
			current.marker = nil
		end
	end
end

-- Her kare: sürükleme sürerken önizlemeyi (kral bekleme ilerlemesi dahil) yenile.
function Input.update()
	local current = pointer
	if current ~= nil and current.dragging and current.lastScreen ~= nil then
		updatePreview(current, current.lastScreen :: Vector2)
	end
end

-- Kule sürüklemesini komut göndermeden bırak (ikinci parmak, ölüm vb.).
local function cancelPointer()
	local current = pointer
	pointer = nil
	if current then
		clearPreview(current)
	end
end

-- Grup gönderimi: her kuleden kendi yoluyla ayrı `DeployForce`. Kralın olduğu kule gönderilmez.
-- Yolu olmayan, menzili yetmeyen ya da kaybedilen kule atlanır; sunucu hepsini yine doğrular.
local function deployGroup(current: Pointer, target: number, commands: Commands)
	local me = WorldView.me()
	local ids = {}
	for id in group do
		table.insert(ids, id)
	end
	table.sort(ids)
	task.spawn(function()
		for _, id in ids do
			local record = WorldView.record(id)
			if
				record ~= nil
				and record.o == me
				and record.u[Unit.Ruler + 1] == 0
				and id ~= target
			then
				local hasStrength, maxEdge = dragLimits(record)
				if hasStrength then
					local path = findPath({ source = id, maxEdgeDistance = maxEdge } :: any, target)
					if path ~= nil and (maxEdge ~= nil or #path <= Path.MAX_PATH_ROADS) then
						commands.deployForce(id, path)
						task.wait(GROUP_SEND_GAP)
					end
				end
			end
		end
	end)
	current.dragging = false
end

local function finish(screen: Vector2, commands: Commands)
	local current = pointer
	if current == nil then
		return
	end
	cancelPointer()

	local target = towerAt(screen)
	if not current.dragging or target == nil or target == current.source then
		-- Tıklama: kendi kuleyi seç / seçimi kaldır. Shift: gruba ekle / gruptan çıkar.
		if target == current.source and isShift() then
			setSelected(nil)
			local ring = group[current.source]
			if ring then
				ring.destroy()
				group[current.source] = nil
			elseif groupSize() < GROUP_MAX then
				addToGroup(current.source)
			end
			return
		end
		clearGroup()
		if target == current.source then
			setSelected(if selected == current.source then nil else current.source)
		else
			setSelected(nil)
		end
		return
	end

	local record = WorldView.record(current.source)
	if record == nil then
		return
	end
	if (group[current.source] :: GroundRing.Ring?) ~= nil and groupSize() > 1 then
		deployGroup(current, target, commands)
		return
	end
	local path = findPath(current, target)
	if selected ~= current.source then
		setSelected(nil)
	end
	if path == nil then
		print("[robgame] no path to target")
		return
	end
	-- `Path::validate`: menzilsiz birlikte en fazla MAX_PATH_ROADS kule (sunucu da reddeder).
	if current.maxEdgeDistance == nil and #path > Path.MAX_PATH_ROADS then
		print("[robgame] path too long")
		return
	end
	-- Kral tehlikeli yoldan ancak hedefte RULER_DRAG_DELAY beklenince gider (game.rs).
	if current.hover ~= target then
		current.hover = target
		current.hoverStart = os.clock()
	end
	if needsRulerDelay(current, path) and os.clock() - current.hoverStart < RULER_DRAG_DELAY then
		print("[robgame] hold on the target to move your king through danger")
		return
	end
	if current.supply then
		-- Aynı hat → kaldır (game.rs: `(source_tower.supply_line != Some(&path)).then_some(path)`).
		commands.setSupplyLine(current.source, if sameList(record.sl, path) then nil else path)
	else
		commands.deployForce(current.source, path)
	end
end

-- Shift+R (ya da Hud düğmesi): seçili kulenin hattı, yoksa `held()` doğru kaldıkça tick başına
-- bir hat (game.rs).
function Input.clearSupplyLines(held: () -> boolean)
	local commands = commandsRef
	if commands == nil then
		return
	end
	if selected ~= nil then
		local record = WorldView.record(selected)
		if record and record.sl ~= nil then
			commands.setSupplyLine(selected, nil)
		end
		return
	end
	task.spawn(function()
		while held() do
			local towers = WorldView.ownSupplyLineTowers()
			if #towers == 0 then
				break
			end
			commands.setSupplyLine(towers[1], nil)
			task.wait(Ticks.PERIOD_SECS)
		end
	end)
end

-- Sol tuş / tek parmak basışı: kendi kulesiyse yol çizimi, değilse dokun/kaydır.
local function beginPress(screen: Vector2, touch: InputObject?)
	local source = towerAt(screen)
	local me = WorldView.me()
	local record = if source then WorldView.record(source) else nil
	if source == nil or record == nil or me == nil or record.o ~= me then
		press = { touch = touch, start = screen, panning = false }
		return
	end
	local _, maxEdge, shorter = dragLimits(record)
	local supply = selected == source
		and generatesMobileUnits(record)
		and not shorter
		and (group[source] :: GroundRing.Ring?) == nil
	-- Birimsiz kuleden yalnız ikmal hattı sürüklenebilir; yine de tıklama (seçim) için takip edilir.
	pointer = {
		touch = touch,
		source = source,
		start = screen,
		dragging = false,
		supply = supply,
		maxEdgeDistance = maxEdge,
		preview = {},
		marker = nil,
		previewTarget = nil,
		previewPath = nil,
		previewViable = false,
		previewPerilous = false,
		lastScreen = nil,
		hover = source,
		hoverStart = os.clock(),
	}
end

local function movePointer(current: Pointer, screen: Vector2)
	if not current.dragging and (screen - current.start).Magnitude >= DRAG_THRESHOLD then
		local record = WorldView.record(current.source)
		local hasStrength = if record then (strengthEdge(record)) else false
		current.dragging = hasStrength or current.supply
	end
	if current.dragging then
		updatePreview(current, screen)
	end
end

local function movePress(current: Press, screen: Vector2)
	if not current.panning and (screen - current.start).Magnitude >= DRAG_THRESHOLD then
		current.panning = true
		Camera.grab(current.start)
	end
	if current.panning then
		Camera.moveGrab(screen)
	end
end

local function endPress(current: Press)
	press = nil
	if current.panning then
		Camera.grab(nil)
	else
		-- game.rs: başka bir kuleye tıklama onu seçer (aynı kuleye ikinci tıklama kaldırır);
		-- kule yoksa seçim kalkar.
		clearGroup()
		local target = towerAt(current.start)
		setSelected(if target ~= nil and target ~= selected then target else nil)
	end
end

-- Sürükleme sürüyor mu (panel gizlenir).
function Input.isDragging(): boolean
	local current = pointer
	return current ~= nil and current.dragging
end

local function midpoint(g: Gesture): (Vector2, number)
	local a, b = screenOf(g.a), screenOf(g.b)
	return (a + b) / 2, (a - b).Magnitude
end

-- İkinci parmak: süren kule sürüklemesi ve kaydırma iptal, iki parmak hareketi başlar.
local function beginGesture(a: InputObject, b: InputObject)
	cancelPointer()
	press = nil
	local g: Gesture = { a = a, b = b, distance = 0 }
	local mid, distance = midpoint(g)
	g.distance = distance
	gesture = g
	Camera.grab(mid)
end

local function moveGesture(g: Gesture)
	local mid, distance = midpoint(g)
	Camera.moveGrab(mid)
	local delta = PINCH_ZOOM_PER_PIXEL * (g.distance - distance)
	g.distance = distance
	local anchor = Camera.grabAnchor()
	if anchor ~= nil and delta ~= 0 then
		Camera.multiplyZoom(anchor, 2 ^ (delta * (1 / 3)))
	end
end

-- Ölüm ya da yeniden doğuşta yarım kalan girdileri bırak.
function Input.setEnabled(value: boolean)
	enabled = value
end

-- İmlecin altındaki gönderilebilir kendi kulesi: fareyle ne seçileceği görünsün.
local function updateHover(screen: Vector2)
	local id = if enabled and pointer == nil then towerAt(screen) else nil
	local record = if id then WorldView.record(id) else nil
	local me = WorldView.me()
	local show = record ~= nil and me ~= nil and record.o == me and (strengthEdge(record))
	if hoverRing == nil then
		if not show then
			return
		end
		hoverRing = groundRing("HoverRing", DEPLOY_COLOR)
	end
	local ring = hoverRing :: GroundRing.Ring
	ring.setTransparency(if show then 0.35 else 1)
	if show then
		local at = WorldView.position(id :: number)
		ring.setCFrame(CFrame.new(at.X, 0.65, at.Z))
	end
end

function Input.reset()
	cancelPointer()
	clearGroup()
	press = nil
	gesture = nil
	rightPanning = false
	table.clear(touches)
	Camera.grab(nil)
	setSelected(nil)
end

function Input.start(commands: Commands)
	commandsRef = commands

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not enabled then
			return
		end
		local groupIndex = GROUP_KEYS[input.KeyCode]
		if groupIndex ~= nil then
			if isShift() then
				Input.selectGroup(groupIndex)
			else
				Input.cycleGroup(groupIndex)
			end
			return
		end
		if input.KeyCode == Enum.KeyCode.T then
			showSimilar()
			return
		end
		if input.KeyCode == Enum.KeyCode.X then
			clearGroup()
			setSelected(nil)
			return
		end
		if input.KeyCode == Enum.KeyCode.Space then
			commands.jumpToAlert()
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			if isShift() then
				Input.clearSupplyLines(function()
					return UserInputService:IsKeyDown(Enum.KeyCode.R) and isShift()
				end)
			end
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton2 then
			-- game.rs: sağ tuş basılıyken kaydır.
			rightPanning = true
			Camera.grab(screenOf(input))
		elseif kind == Enum.UserInputType.Touch then
			table.insert(touches, input)
			if #touches == 2 then
				beginGesture(touches[1], touches[2])
			elseif #touches == 1 and pointer == nil and press == nil then
				beginPress(screenOf(input), input)
			end
		elseif kind == Enum.UserInputType.MouseButton1 then
			if pointer == nil and press == nil and gesture == nil then
				beginPress(screenOf(input), nil)
			end
		end
	end)

	UserInputService.InputChanged:Connect(function(input, processed)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseWheel then
			if not processed and enabled then
				-- Tekerlek ileri (+Z) → yakınlaş (kodiak: deltaY < 0 → raw_zoom(-0.5)).
				Camera.rawZoom(screenOf(input), -math.sign(input.Position.Z) * WHEEL_ZOOM_STEP)
			end
		elseif kind == Enum.UserInputType.MouseMovement then
			local screen = screenOf(input)
			updateHover(screen)
			if rightPanning then
				Camera.moveGrab(screen)
			end
			local current = pointer
			if current ~= nil and current.touch == nil then
				movePointer(current, screen)
			end
			local currentPress = press
			if currentPress ~= nil and currentPress.touch == nil then
				movePress(currentPress, screen)
			end
		elseif kind == Enum.UserInputType.Touch then
			local g = gesture
			if g ~= nil then
				if input == g.a or input == g.b then
					moveGesture(g)
				end
				return
			end
			local current = pointer
			if current ~= nil and current.touch == input then
				movePointer(current, screenOf(input))
			end
			local currentPress = press
			if currentPress ~= nil and currentPress.touch == input then
				movePress(currentPress, screenOf(input))
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.T then
			hideSimilar()
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton2 then
			if rightPanning then
				rightPanning = false
				Camera.grab(nil)
			end
		elseif kind == Enum.UserInputType.MouseButton1 then
			local current = pointer
			if current ~= nil and current.touch == nil then
				finish(screenOf(input), commands)
			end
			local currentPress = press
			if currentPress ~= nil and currentPress.touch == nil then
				endPress(currentPress)
			end
		elseif kind == Enum.UserInputType.Touch then
			local index = table.find(touches, input)
			if index ~= nil then
				table.remove(touches, index)
			end
			local g = gesture
			if g ~= nil then
				-- Kalan parmak, kaldırılana kadar bir şey yapmaz.
				if input == g.a or input == g.b then
					gesture = nil
					Camera.grab(nil)
				end
				return
			end
			local current = pointer
			if current ~= nil and current.touch == input then
				finish(screenOf(input), commands)
			end
			local currentPress = press
			if currentPress ~= nil and currentPress.touch == input then
				endPress(currentPress)
			end
		end
	end)
end

return Input
