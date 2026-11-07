--!strict
-- Görselleştirme: kuleler 3D model (ReplicatedStorage.TowerMeshes kalıpları, Shared/Art/TowerArt),
-- modeli olmayan tip kutu; yollar ince çubuk, sahibe göre renk. Model dokusunun saydam alanlarından
-- (bayrak, şerit, taban kenarı) MeshPart.Color görünür. Simülasyon yok; yalnız sunucu verisini çizer.
-- Kiomet'te karşılığı `client/src/game.rs` çizim kısmı, `road.rs`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local Ticks = require(Sim.Ticks)
local TowerId = require(Sim.TowerId)
local TowerTypeId = require(Sim.TowerTypeId)
local Unit = require(Sim.Unit)

local Audio = require(script.Parent.Audio)
local Cosmetics = require(script.Parent.Cosmetics)
local Effects = require(script.Parent.Effects)
local Icons = require(script.Parent.Icons)
local Biome = require(script.Parent.Biome)
local GroundRing = require(script.Parent.GroundRing)
local Theme = require(script.Parent.Theme)
local TowerIdle = require(script.Parent.TowerIdle)

export type TowerRecord = {
	id: number,
	t: number,
	o: number,
	d: number,
	u: { number },
	sl: { number }?,
}

local WorldView = {}

-- Dünya birimi başına stud (kule aralığı 5 birim → 15 stud).
WorldView.STUDS_PER_UNIT = 3

local TOWER_SIZE = Vector3.new(4, 2, 4)
-- Yer katmanları (2026-11-05): uzakta derinlik hassasiyeti ~0,05 stud; katmanlar arası ≥ 0,08.
-- Kara 0 · bölge lekeleri 0,08–0,24 · yol 0,32 · bölge tülü 0,42 · sınır 0,5 · birlik 0,37 ·
-- halkalar 0,6–0,72 · sınır bulutları 0,8+. Kuleler bu katmanların üstünde durur.
-- Yol bölge tülünün altında: tül yolu da boyar, yol zemine işlenmiş durur (2026-11-05).
WorldView.ROAD_Y = 0.32
WorldView.TOWER_LIFT = 0.45
-- Yol: kenarları çimene karışan dokulu şerit (Magnific yol dokusu + yumuşak alfa kenar), görünmez
-- parçanın üst yüzünde Texture. 2026-11-05 Studio'da ölçüldü: Texture tam saydam parçada çizilir,
-- üst yüzde U = parça X (genişlik), V = parça Z (boy). İlk denemede görünmemesi büyük olasılıkla
-- yeni yüklenen görselin henüz onaylanmamasıydı; görsel önden yüklenir (main.client).
local ROAD_WIDTH = 2.6
-- Çekirdek görünen genişliğe yakın: yarı saydam saçak lekelerin altında kalsa da yol aynı kalınlıkta.
local ROAD_CORE_WIDTH = 1.3
WorldView.PAD_TEXTURE = "rbxassetid://93301527347092"
WorldView.ROAD_TEXTURE = "rbxassetid://100324463837458"

local COLOR_MINE = Theme.colors.own
local COLOR_ENEMY = Theme.colors.enemy
-- `Color::Purple`: karşılıklı ittifak (`have_alliance`).
local COLOR_ALLY = Theme.colors.ally
local COLOR_NEUTRAL = Theme.colors.neutral
-- Yol dokusu (CrownviaRoad) kendi rengini taşır.
local COLOR_ROAD = Theme.colors.textureTint
local COLOR_ROAD_DESERT = Color3.fromRGB(205, 178, 152)
local COLOR_SUPPLY_MINE = Theme.colors.route
-- Akış dokusu: ucu yukarı chevron (Input.luau ile aynı görsel).
local SUPPLY_FLOW_TEXTURE = "rbxassetid://101512903999693"
local SUPPLY_HEIGHT = 0.8

-- `delay` hem yükseltmede hem EMP'de kurulur (kaynakta ayrım yok). İstemci geçişi görürse ayırır:
-- tip değişip delay başladıysa yükseltme, tip aynı kalıp delay arttıysa EMP (TowerTick EMP isabeti).
type DelayKind = "Upgrade" | "Emp" | "Unknown"

local COLOR_STATUS_EMP = Color3.fromRGB(90, 230, 255)
local COLOR_STATUS_UPGRADE = Color3.fromRGB(255, 205, 100)
local COLOR_STATUS_UNKNOWN = Color3.fromRGB(220, 220, 220)

type TowerView = {
	part: BasePart,
	billboard: BillboardGui,
	-- Başlık, birim satırı, sahip.
	label: TextLabel,
	units: Frame,
	owner: TextLabel,
	-- Devre dışı kule (delay > 0): kalan süre. Sebep yalnız geçişi gördüysek bilinir.
	statusBillboard: BillboardGui,
	status: TextLabel,
	delayKind: DelayKind?,
	-- Pasif kulenin altında nabız atan halka (yükseltme altın, EMP mavi).
	statusRing: GroundRing.Ring?,
	record: TowerRecord,
	-- Kalıp yokken kutu çizildi; kalıp gelince modelle değiştirilir.
	boxed: boolean,
}

type State = {
	me: number?,
	folder: Folder,
	roadsFolder: Folder,
	towersFolder: Folder,
	towers: { [number]: TowerView },
	roads: { [string]: Part },
	players: { [number]: string },
	bots: { [number]: boolean },
	-- Benim ittifak isteklerim ve bana gelen istekler (Delta `allies` / `incoming`).
	allies: { [number]: boolean },
	incoming: { [number]: boolean },
	-- `tower_counts` (yükseltme ön koşulları), tip → sayı.
	towerCounts: { [number]: number },
	selected: number?,
	-- Kule başına ikmal hattı çizimi ve imzası
	supplyLines: { [number]: { parts: { Part }, signature: string } },
	-- Seçim halkası: kulenin altında yerde ince, nabız atan halka (SelectionBox tel kafesi kabaydı).
	selection: GroundRing.Ring,
	selectionTarget: BasePart?,
}

local state: State? = nil

-- Son `applyTowers` çağrısında sahibi değişmeden birim sayısı düşen kuleler (kule → düşüş).
-- Aynı delta'da varan düşman birliği bunu "-N" olarak gösterir (ForceView).
local drops: { [number]: number } = {}

-- Kule değişince haber verilir (bölge katmanı; Territory WorldView'u kullandığı için geri çağırma).
local changedHook: ((id: number?) -> ())? = nil

function WorldView.setChangedHook(hook: (id: number?) -> ())
	changedHook = hook
end

local function notifyChanged(id: number?)
	if changedHook then
		changedHook(id)
	end
end

-- TowerId → dünya konumu (Rust y yukarı = kuzey; Roblox'ta -Z).
function WorldView.position(id: number): Vector3
	local x, y = TowerId.integerPosition(id)
	return Vector3.new(x * WorldView.STUDS_PER_UNIT, 0, -y * WorldView.STUDS_PER_UNIT)
end

local function getState(): State
	if state == nil then
		local folder = Instance.new("Folder")
		folder.Name = "RobgameWorld"
		folder.Parent = workspace
		local roadsFolder = Instance.new("Folder")
		roadsFolder.Name = "Roads"
		roadsFolder.Parent = folder
		local towersFolder = Instance.new("Folder")
		towersFolder.Name = "Towers"
		towersFolder.Parent = folder
		local selection = GroundRing.new("Selection", 10, Color3.new(1, 1, 1), folder)
		selection.setTransparency(1)
		-- Hafif nabız: halka yavaşça genişleyip daralır (tek, sonsuz tekrarlı tween).
		selection.pulse(10, 11, 0.9)
		state = {
			me = nil,
			folder = folder,
			roadsFolder = roadsFolder,
			towersFolder = towersFolder,
			towers = {},
			roads = {},
			players = {},
			bots = {},
			allies = {},
			incoming = {},
			towerCounts = {},
			selected = nil,
			supplyLines = {},
			selection = selection,
			selectionTarget = nil,
		}
	end
	return state :: State
end

local function ownerColor(owner: number): Color3
	local me = getState().me
	if owner == 0 then
		return COLOR_NEUTRAL
	elseif owner == me then
		return COLOR_MINE
	elseif WorldView.haveAlliance(me, owner) then
		return COLOR_ALLY
	end
	return COLOR_ENEMY
end

-- Kule etiketi: başlık (tip, kralın kulesinde taç), birim ikonları + sayılar, sahip.
local function titleText(record: TowerRecord): string
	return TowerTypeId.name(record.t)
end

local function ownerText(record: TowerRecord): string
	return if record.o ~= 0 then WorldView.playerLabel(record.o) else ""
end

-- Kule düğümü (Codex tasarımı): sahip renginde rozet + toplam birim sayısı, kral varsa taç.
-- Kule adı yalnız seçiliyken, sahip adı bölge adında (Territory) görünür: harita sade kalır.
local function unitTotal(record: TowerRecord): number
	local total = 0
	for unit = 0, Unit.COUNT - 1 do
		if unit ~= Unit.Ruler then
			total += record.u[unit + 1]
		end
	end
	return total
end

-- Kule rozeti alanı (stud): rozet satırı + üstünde taç/başlık payı.
local BADGE_HEIGHT = 1.3
local BADGE_HEADROOM = 3
local BADGE_LIFT = Vector3.new(0, BADGE_HEADROOM / 2, 0)

local function refreshUnits(row: Frame, record: TowerRecord, color: Color3)
	local pill = row:FindFirstChild("Pill") :: Frame?
	if pill == nil then
		local p = Instance.new("Frame")
		p.Name = "Pill"
		p.AnchorPoint = Vector2.new(0.5, 0.5)
		p.Position = UDim2.fromScale(0.5, 0.5)
		p.Size = UDim2.fromScale(0.45, 1)
		p.BorderSizePixel = 0
		p.Parent = row
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = p
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(1, 1, 1)
		stroke.Transparency = 0.2
		stroke.Thickness = 1.5
		stroke.Parent = p
		local text = Instance.new("TextLabel")
		text.Name = "Count"
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.TextScaled = true
		text.FontFace = Theme.fonts.heading
		text.TextColor3 = Color3.new(1, 1, 1)
		text.Parent = p
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0.12, 0)
		padding.PaddingBottom = UDim.new(0.12, 0)
		padding.Parent = text
		local crown = Instance.new("ImageLabel")
		crown.Name = "Crown"
		crown.AnchorPoint = Vector2.new(0.5, 1)
		crown.Position = UDim2.fromScale(0.5, -0.05)
		crown.Size = UDim2.fromScale(1, 1.3)
		crown.BackgroundTransparency = 1
		crown.Image = Icons.crown
		crown.ScaleType = Enum.ScaleType.Fit
		crown.Parent = p
		pill = p
	end
	local frame = pill :: Frame
	local count = frame:FindFirstChild("Count") :: TextLabel
	local crown = frame:FindFirstChild("Crown") :: ImageLabel
	local text = tostring(unitTotal(record))
	count.Text = text
	frame.Size = UDim2.fromScale(0.22 + 0.11 * #text, 1)
	-- Altın rozet: bu kuleden birlik gönderilebilir (renk dili: altın = eylem).
	local ready = false
	if record.o ~= 0 and record.o == getState().me then
		for unit = 0, Unit.COUNT - 1 do
			if record.u[unit + 1] > 0 and Unit.isMobile(unit, record.t) then
				ready = true
				break
			end
		end
	end
	frame.BackgroundColor3 = if ready
		then Theme.colors.gold
		else color:Lerp(Color3.new(0, 0, 0), 0.15)
	count.TextColor3 = if ready then Theme.colors.background else Color3.new(1, 1, 1)
	crown.Visible = record.u[Unit.Ruler + 1] > 0
	-- Seçili kule başlığı tacın üstüne çıkar, üst üste binmez.
	local title = row.Parent and row.Parent:FindFirstChild("Title") :: TextLabel?
	if title then
		title.Position = UDim2.fromScale(0, if crown.Visible then -2.2 else -1.1)
	end
	-- Kozmetik taç (docs/HESAP_MAGAZA.md): aynı yer ve boy, yalnız görsel; kendi renginde.
	local custom = if record.o ~= 0 then Cosmetics.image(record.o, "crown") else nil
	crown.Image = custom or Icons.crown
	-- Sahipsiz ve boş kulede "0" rozeti gürültüdür: gizle (yalnız gösterim).
	frame.Visible = record.o ~= 0 or text ~= "0"
end

local function meshTemplate(towerType: number): MeshPart?
	local folder = ReplicatedStorage:FindFirstChild("TowerMeshes")
	local template = if folder then folder:FindFirstChild(TowerTypeId.name(towerType)) else nil
	return if template and template:IsA("MeshPart") then template else nil
end

-- Kulenin gövdesi: tipinin modeli, yoksa kutu.
local function makeBody(record: TowerRecord): (BasePart, boolean)
	local template = meshTemplate(record.t)
	local part: BasePart
	if template then
		part = template:Clone()
	else
		local box = Instance.new("Part")
		box.Anchored = true
		box.CanCollide = false
		box.Size = TOWER_SIZE
		part = box
	end
	part.Name = "Tower_" .. TowerId.toString(record.id)
	part.Position = WorldView.position(record.id)
		+ Vector3.new(0, WorldView.TOWER_LIFT + part.Size.Y / 2, 0)
	part:SetAttribute("TowerId", record.id)
	-- Temas gölgesi: kaide kenarında koyu, dışa doğru söner; kaide zemine otursun (2026-11-05; yalnız görsel).
	local pad = Instance.new("Part")
	pad.Name = "Pad"
	pad.Anchored = true
	pad.CanCollide = false
	pad.CanQuery = false
	pad.CanTouch = false
	pad.CastShadow = false
	pad.Transparency = 1
	pad.Size = Vector3.new(10, 0.05, 10)
	local at = WorldView.position(record.id)
	-- Yolların (0,32) üstünde, bölge tülünün (0,42) altında.
	pad.CFrame = CFrame.new(at.X, 0.37, at.Z)
	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Top
	decal.Texture = WorldView.PAD_TEXTURE
	decal.Parent = pad
	pad.Parent = part
	part.Parent = getState().towersFolder
	return part, template == nil
end

local function labelOffset(part: BasePart): Vector3
	return Vector3.new(0, part.Size.Y / 2 + 1.5, 0)
end

local function createTower(record: TowerRecord): TowerView
	local part, boxed = makeBody(record)

	local billboard = Instance.new("BillboardGui")
	-- Stud ölçekli: uzaklaştıkça küçülür, üst üste binmez.
	-- BillboardGui sınır dışını çizmez: rozetin üstündeki taç ve başlık için üstte boş pay var
	-- (taç bu yüzden hiç görünmüyordu). Rozet alttaki `content` satırında, eski yerinde.
	billboard.Size = UDim2.fromScale(6, BADGE_HEIGHT + BADGE_HEADROOM)
	billboard.StudsOffset = labelOffset(part) + BADGE_LIFT
	billboard.MaxDistance = 400
	billboard.Parent = part
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.AnchorPoint = Vector2.new(0, 1)
	content.Position = UDim2.fromScale(0, 1)
	content.Size = UDim2.fromScale(1, BADGE_HEIGHT / (BADGE_HEIGHT + BADGE_HEADROOM))
	content.Parent = billboard

	local label = Instance.new("TextLabel")
	label.Name = "Title"
	-- Başlık rozetin üstünde; yalnız seçiliyken.
	label.Visible = false
	label.Position = UDim2.fromScale(0, -1.1)
	label.Size = UDim2.fromScale(1, 0.9)
	label.BackgroundTransparency = 1
	label.TextColor3 = Theme.colors.text
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.FontFace = Theme.fonts.heading
	label.Parent = content

	local units = Instance.new("Frame")
	units.Name = "Units"
	units.Size = UDim2.fromScale(1, 1)
	units.BackgroundTransparency = 1
	units.Parent = content

	local owner = Instance.new("TextLabel")
	owner.Visible = false
	owner.Position = UDim2.fromScale(0, 0.7)
	owner.Size = UDim2.fromScale(1, 0.26)
	owner.BackgroundTransparency = 1
	owner.TextColor3 = Theme.colors.muted
	owner.TextStrokeTransparency = 0.4
	owner.TextScaled = true
	owner.FontFace = Theme.fonts.body
	owner.Parent = content

	local statusBillboard = Instance.new("BillboardGui")
	statusBillboard.Size = UDim2.fromScale(8, 1.6)
	statusBillboard.StudsOffset = labelOffset(part) + Vector3.new(0, 3.2, 0)
	statusBillboard.MaxDistance = 400
	statusBillboard.Enabled = false
	statusBillboard.Parent = part

	local status = Instance.new("TextLabel")
	status.Size = UDim2.fromScale(1, 1)
	status.BackgroundTransparency = 1
	status.TextStrokeTransparency = 0.3
	status.TextScaled = true
	status.FontFace = Theme.fonts.heading
	status.Parent = statusBillboard

	return {
		part = part,
		billboard = billboard,
		label = label,
		units = units,
		owner = owner,
		statusBillboard = statusBillboard,
		status = status,
		delayKind = nil,
		statusRing = nil,
		record = record,
		boxed = boxed,
	}
end

local function setStatusRing(view: TowerView, color: Color3?)
	local ring = view.statusRing
	if color == nil then
		if ring then
			ring.destroy()
			view.statusRing = nil
		end
		return
	end
	if ring == nil then
		local r = GroundRing.new("StatusRing", 9, color, getState().towersFolder)
		local at = WorldView.position(view.record.id)
		r.setCFrame(CFrame.new(at.X, 0.6, at.Z))
		view.statusRing = r
		ring = r
	end
	(ring :: GroundRing.Ring).setColor(color)
end

local function updateStatus(view: TowerView, previous: TowerRecord?)
	local record = view.record
	if record.d <= 0 then
		view.delayKind = nil
		view.statusBillboard.Enabled = false
		setStatusRing(view, nil)
		return
	end
	if previous == nil then
		view.delayKind = view.delayKind or "Unknown"
	elseif previous.t ~= record.t then
		view.delayKind = "Upgrade"
	elseif record.d > previous.d then
		view.delayKind = "Emp"
	elseif view.delayKind == nil then
		view.delayKind = "Unknown"
	end
	local seconds = math.ceil(record.d * Ticks.PERIOD_SECS)
	local kind = view.delayKind
	if kind == "Emp" then
		view.status.Text = string.format("EMP %ds", seconds)
		view.status.TextColor3 = COLOR_STATUS_EMP
		setStatusRing(view, COLOR_STATUS_EMP)
	elseif kind == "Upgrade" then
		view.status.Text = string.format("Upgrading %ds", seconds)
		view.status.TextColor3 = COLOR_STATUS_UPGRADE
		setStatusRing(view, COLOR_STATUS_UPGRADE)
	else
		view.status.Text = string.format("Inactive %ds", seconds)
		view.status.TextColor3 = COLOR_STATUS_UNKNOWN
		setStatusRing(view, COLOR_STATUS_UNKNOWN)
	end
	view.statusBillboard.Enabled = true
end

-- Tip değişti (yükseltme) ya da kalıp sonradan geldi: gövdeyi yenile, etiketi taşı.
local function rebuildBody(view: TowerView)
	local s = getState()
	local old = view.part
	local part, boxed = makeBody(view.record)
	view.billboard.StudsOffset = labelOffset(part) + BADGE_LIFT
	view.billboard.Parent = part
	view.statusBillboard.StudsOffset = labelOffset(part) + Vector3.new(0, 3.2, 0)
	view.statusBillboard.Parent = part
	if s.selectionTarget == old then
		s.selectionTarget = part
	end
	old:Destroy()
	view.part, view.boxed = part, boxed
end

local function roadKey(a: number, b: number): string
	if a < b then
		return a .. ":" .. b
	end
	return b .. ":" .. a
end

-- Yumuşak yol yarısının rengi: yol tonu, ucundaki kule sahipliyse bölge tülü kadar o renge.
-- SoftA +Z yarısı (lookAt'in arkası = `A` ucu), SoftB -Z yarısı (`B` ucu).
local function tintRoad(road: Part)
	local s = getState()
	local base = Color3.new(
		road:GetAttribute("BaseR") :: number,
		road:GetAttribute("BaseG") :: number,
		road:GetAttribute("BaseB") :: number
	)
	-- Bölge içindeki yol: yumuşak saçak gizli, yalnız opak çekirdek (bölge tülü onu her yerde aynı
	-- boyar). Önceden boyanmış saçak, tülün sınırı yol ortasında olmadığından yarı yarı griye
	-- kayıyordu (2026-11-05). Bölge dışında saçak görünür.
	local claimed = false
	for _, attr in { "A", "B" } do
		local view = s.towers[road:GetAttribute(attr) :: number]
		if view and view.record.o ~= 0 then
			claimed = true
		end
	end
	for _, name in { "SoftA", "SoftB" } do
		local soft = road:FindFirstChild(name)
		local texture = if soft then soft:FindFirstChildOfClass("Texture") else nil
		if texture then
			texture.Color3 = base
			texture.Transparency = if claimed then 1 else 0
		end
	end
end

local function tintRoadsOf(id: number)
	local s = getState()
	for _, other in TowerId.neighbors(id) do
		local road = s.roads[roadKey(id, other)]
		if road then
			tintRoad(road)
		end
	end
end

local function ensureRoads(id: number)
	local s = getState()
	for _, other in TowerId.neighbors(id) do
		if s.towers[other] ~= nil then
			local key = roadKey(id, other)
			if not s.roads[key] then
				local from = WorldView.position(id)
				local to = WorldView.position(other)
				local road = Instance.new("Part")
				road.Name = "Road"
				road.Anchored = true
				road.CanCollide = false
				road.CanQuery = false
				road.CanTouch = false
				road.CastShadow = false
				road.Transparency = 1
				local length = (to - from).Magnitude
				road.Size = Vector3.new(ROAD_WIDTH, 0.05, length)
				-- Üst yüzü WorldView.ROAD_Y'de.
				local lift = Vector3.new(0, WorldView.ROAD_Y - 0.025, 0)
				road.CFrame = CFrame.lookAt((from + to) / 2 + lift, to + lift)
				-- Çölde yol kumla aynı tonda kayboluyordu: koyu, sıkıştırılmış toprak tonu.
				-- Çöl lekesi komşu hücrelere taşar: iki ucun 3×3 çevresinde çöl varsa koyu ton.
				local sandy = false
				for _, endId in { id, other } do
					local ex, ey = TowerId.x(endId), TowerId.y(endId)
					for dx = -1, 1 do
						for dy = -1, 1 do
							if Biome.at(ex + dx, ey + dy) == "desert" then
								sandy = true
							end
						end
					end
				end
				local roadColor = if sandy then COLOR_ROAD_DESERT else COLOR_ROAD
				-- Yol yalnız opak şerit (2026-11-05): yarı saydam yumuşak kenar katmanı Roblox'un
				-- yarı saydam sıralamasında bölge tülüyle yer değiştirip yolları yer yer gri, düz ya
				-- da geçişli gösteriyordu. Bölge tülünün altında: tül yolu da tutarlı boyar.
				local core = Instance.new("Part")
				core.Name = "RoadCore"
				core.Anchored = true
				core.CanCollide = false
				core.CanQuery = false
				core.CanTouch = false
				core.CastShadow = false
				core.Material = Enum.Material.Sand
				core.MaterialVariant = "CrownviaRoad"
				core.Color = roadColor
				core.Size = Vector3.new(ROAD_CORE_WIDTH, 0.05, length)
				core.CFrame = road.CFrame - Vector3.new(0, 0.02, 0)
				core.Parent = road
				-- Yumuşak kenar (2026-11-06): bölge lekeleri kalktı (zemin Terrain), çakışan yarı saydam
				-- katman yalnız bölge tülü; tintRoad bölge içindeki yolda kenarı gizler.
				for half = 1, 2 do
					local soft = Instance.new("Part")
					soft.Name = if half == 1 then "SoftA" else "SoftB"
					soft.Anchored = true
					soft.CanCollide = false
					soft.CanQuery = false
					soft.CanTouch = false
					soft.CastShadow = false
					soft.Transparency = 1
					soft.Size = Vector3.new(ROAD_WIDTH, 0.05, length / 2)
					local sign = if half == 1 then 1 else -1
					soft.CFrame = road.CFrame * CFrame.new(0, 0.01, sign * length / 4)
					local texture = Instance.new("Texture")
					texture.Face = Enum.NormalId.Top
					texture.Texture = WorldView.ROAD_TEXTURE
					texture.Color3 = roadColor
					texture.StudsPerTileU = ROAD_WIDTH
					texture.StudsPerTileV = 6
					texture.OffsetStudsV = (length / 4) % 6
					texture.Parent = soft
					soft.Parent = road
				end
				road:SetAttribute("BaseR", roadColor.R)
				road:SetAttribute("BaseG", roadColor.G)
				road:SetAttribute("BaseB", roadColor.B)
				road:SetAttribute("A", id)
				road:SetAttribute("B", other)
				road.Parent = s.roadsFolder
				s.roads[key] = road
				tintRoad(road)
			end
		end
	end
end

local function removeRoads(id: number)
	local s = getState()
	for _, other in TowerId.neighbors(id) do
		local key = roadKey(id, other)
		local road = s.roads[key]
		if road then
			road:Destroy()
			s.roads[key] = nil
		end
	end
end

local function clearSupplyLine(id: number)
	local s = getState()
	local drawn = s.supplyLines[id]
	if drawn then
		for _, part in drawn.parts do
			part:Destroy()
		end
		s.supplyLines[id] = nil
	end
end

-- İkmal hattını yol parçaları boyunca çizer (kaynakta client/src/game.rs supply line çizimi).
-- Kaynakta seçili hat tam parlak, diğerleri silik (game.rs `alpha`). Bizde hatlar hep görünür,
-- seçili kulenin hattı varsa o öne çıkar, ötekiler geri çekilir.
local function emphasizeSupplyLine(id: number)
	local s = getState()
	local line = s.supplyLines[id]
	if line == nil then
		return
	end
	local focused = s.selected ~= nil and s.supplyLines[s.selected] ~= nil
	local isSelected = s.selected == id
	local flow = if isSelected then 0 elseif focused then 0.8 else 0.35
	local glow = if isSelected then 0.5 elseif focused then 1 else 0.85
	local width = if isSelected then 2.2 elseif focused then 1 else 1.3
	for _, part in line.parts do
		local flowBeam = part:FindFirstChild("Flow") :: Beam
		local glowBeam = part:FindFirstChild("Glow") :: Beam
		flowBeam.Transparency = NumberSequence.new(flow)
		flowBeam.Width0, flowBeam.Width1 = width, width
		glowBeam.Transparency = NumberSequence.new(glow)
	end
end

local function drawSupplyLine(record: TowerRecord)
	local s = getState()
	local signature = if record.sl then table.concat(record.sl, ",") else ""
	local drawn = s.supplyLines[record.id]
	if drawn and drawn.signature == signature then
		return
	end
	clearSupplyLine(record.id)
	-- Kaynak yalnız kendi hatlarını çizer (game.rs `tower.player_id == me`); sunucu da
	-- başkasının hattını göndermez.
	local path = record.sl
	if path == nil or record.o ~= s.me then
		return
	end
	local color = COLOR_SUPPLY_MINE
	local parts = {}
	local lift = Vector3.new(0, SUPPLY_HEIGHT, 0)
	for i = 2, #path do
		local from = WorldView.position(path[i - 1]) + lift
		local to = WorldView.position(path[i]) + lift
		-- İkmal hattı (2026-11-05): neon çubuk yerine hedefe akan yeşil ok başları + altında yumuşak
		-- ışık şeridi. Beam ekseni Studio'da ölçüldü (Input.luau): görselin üstü Attachment0'a
		-- bakar, pozitif hız Attachment1'e kaydırır. Attachment0 hedef ucunda, hız negatif.
		local part = Instance.new("Part")
		part.Name = "SupplyLine"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		local length = (to - from).Magnitude
		part.Size = Vector3.new(0.2, 0.2, length)
		part.CFrame = CFrame.lookAt((from + to) / 2, to)
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0, -length / 2)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, 0, length / 2)
		a1.Parent = part
		local glow = Instance.new("Beam")
		glow.Name = "Glow"
		glow.ZOffset = GroundRing.Z_OFFSET
		glow.Attachment0 = a0
		glow.Attachment1 = a1
		glow.Width0 = 1.4
		glow.Width1 = 1.4
		glow.FaceCamera = true
		glow.LightEmission = 0.6
		glow.Transparency = NumberSequence.new(0.78)
		glow.Color = ColorSequence.new(color)
		glow.Parent = part
		local beam = Instance.new("Beam")
		beam.Name = "Flow"
		beam.ZOffset = GroundRing.Z_OFFSET
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Texture = SUPPLY_FLOW_TEXTURE
		beam.TextureMode = Enum.TextureMode.Static
		beam.TextureLength = 2.6
		beam.TextureSpeed = -1.2
		beam.Width0 = 1.4
		beam.Width1 = 1.4
		beam.LightEmission = 0
		beam.FaceCamera = true
		beam.Color = ColorSequence.new(color)
		beam.Parent = part
		part.Parent = s.roadsFolder
		table.insert(parts, part)
	end
	s.supplyLines[record.id] = { parts = parts, signature = signature }
	emphasizeSupplyLine(record.id)
end

local function removeTower(id: number)
	local s = getState()
	local view = s.towers[id]
	if view then
		if s.selectionTarget == view.part then
			s.selectionTarget = nil
			s.selection.setTransparency(1)
		end
		setStatusRing(view, nil)
		view.part:Destroy()
		s.towers[id] = nil
		removeRoads(id)
		clearSupplyLine(id)
		notifyChanged(id)
	end
end

-- "Hello": tam yeniden başlatma.
function WorldView.reset(me: number)
	local s = getState()
	for id in s.towers do
		removeTower(id)
	end
	s.me = me
	table.clear(s.allies)
	table.clear(s.incoming)
	table.clear(s.towerCounts)
	s.selected = nil
end

-- `World::have_alliance`, istemcinin bildiği kadarıyla: yalnız benimle ilgili ittifaklar bilinir.
function WorldView.haveAlliance(a: number?, b: number): boolean
	local s = getState()
	if a == nil then
		return false
	end
	local other = if a == s.me then b elseif b == s.me then a else nil
	if other == nil then
		return false
	end
	return s.allies[other] == true and s.incoming[other] == true
end

-- Delta `allies` / `incoming`: değişince renkler yeniden boyanır.
function WorldView.applyAlliances(allies: { number }, incoming: { number })
	local s = getState()
	local before: { [number]: boolean } = {}
	for id in s.allies do
		if s.incoming[id] then
			before[id] = true
		end
	end
	table.clear(s.allies)
	table.clear(s.incoming)
	for _, id in allies do
		s.allies[id] = true
	end
	for _, id in incoming do
		s.incoming[id] = true
	end
	for _, view in s.towers do
		view.part.Color = ownerColor(view.record.o)
	end
	for _, road in s.roads do
		tintRoad(road)
	end
	notifyChanged(nil)
	-- Yeni karşılıklı ittifak.
	for id in s.allies do
		if s.incoming[id] and not before[id] then
			Audio.world("alliance")
			break
		end
	end
end

-- Benim bu oyuncuya isteğim var mı / bana isteği var mı.
function WorldView.allianceState(other: number): (boolean, boolean)
	local s = getState()
	return s.allies[other] == true, s.incoming[other] == true
end

-- Delta `towerCounts`: dizi, indeks = tip + 1.
function WorldView.applyTowerCounts(counts: { number })
	local s = getState()
	table.clear(s.towerCounts)
	for i, count in counts do
		if count > 0 then
			s.towerCounts[i - 1] = count
		end
	end
end

function WorldView.towerCounts(): { [number]: number }
	return getState().towerCounts
end

function WorldView.selected(): number?
	return getState().selected
end

-- Delta `players`: ad ya da bot bilgisi değişince de gelir (bot aynı kimlikle yeni adla doğar).
-- O oyuncunun görünen kule etiketleri yenilenir.
function WorldView.applyPlayers(players: { { id: number, alias: string, bot: boolean? } })
	local s = getState()
	local changed: { [number]: boolean } = {}
	for _, p in players do
		s.players[p.id] = p.alias
		s.bots[p.id] = p.bot == true
		changed[p.id] = true
	end
	for _, view in s.towers do
		if changed[view.record.o] then
			view.owner.Text = ownerText(view.record)
		end
	end
end

-- Oyuncu etiketi: ad, botsa "(BOT)" ekiyle. Botlar insan gibi gösterilmez.
function WorldView.playerLabel(id: number): string
	local s = getState()
	local name = s.players[id] or ("#" .. id)
	return if s.bots[id] then name .. " (BOT)" else name
end

function WorldView.applyTowers(records: { TowerRecord })
	local s = getState()
	table.clear(drops)
	for _, record in records do
		local view = s.towers[record.id]
		local previous: TowerRecord? = if view then view.record else nil
		if previous and previous.o == record.o then
			local drop = unitTotal(previous) - unitTotal(record)
			if drop > 0 then
				drops[record.id] = drop
			end
		end
		if view == nil then
			view = createTower(record)
			s.towers[record.id] = view
			ensureRoads(record.id)
		end
		local v = view :: TowerView
		local typeChanged = v.record.t ~= record.t
		v.record = record
		updateStatus(v, previous)
		-- Sahiplik değişimi sesleri (yalnız görülen geçiş).
		if previous and previous.o ~= record.o then
			Effects.capture(
				WorldView.position(record.id),
				ownerColor(record.o),
				s.folder,
				if record.o ~= 0 then Cosmetics.get(record.o, "capture") else nil
			)
			if record.o == s.me then
				Audio.worldAt("capture", WorldView.position(record.id))
			elseif previous.o == s.me then
				Audio.worldAt("towerLost", WorldView.position(record.id))
			end
		end
		if typeChanged and previous then
			Effects.upgrade(WorldView.position(record.id), s.folder)
		end
		if typeChanged or (v.boxed and meshTemplate(record.t) ~= nil) then
			rebuildBody(v)
		end
		-- Fetih anı: model kısa bir an küçülüp yaylanarak eski boyuna döner (yalnız görsel).
		if previous and previous.o ~= record.o then
			local part = v.part
			local size = part.Size
			local base = part.Position.Y - size.Y / 2
			part.Size = size * 0.78
			part.Position = Vector3.new(part.Position.X, base + part.Size.Y / 2, part.Position.Z)
			TweenService
				:Create(part, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Size = size,
					Position = Vector3.new(part.Position.X, base + size.Y / 2, part.Position.Z),
				})
				:Play()
		end
		v.part.Color = ownerColor(record.o)
		-- Pasif kule (yükseltme/EMP) tam görünür kalır; durumu halka ve yazı gösterir. Yarı saydam
		-- çizim, takım rengi alanları zaten saydam olan modelde kuleyi neredeyse yok ediyordu.
		v.part.Transparency = 0
		TowerIdle.apply(v.part, record.t, record.o, record.d)
		if previous == nil or previous.o ~= record.o then
			notifyChanged(record.id)
			tintRoadsOf(record.id)
		end
		v.label.Text = titleText(record)
		v.owner.Text = ownerText(record)
		v.owner.TextColor3 = ownerColor(record.o)
		refreshUnits(v.units, record, ownerColor(record.o))
		drawSupplyLine(record)
	end
end

-- Görüşten çıkan ve yok edilen kuleler. Aşama 2'de ikisi de çizimden kalkar;
-- "son bilinen durum" gösterimi Aşama 8'de tanımlanacak (docs/API.md).
function WorldView.removeTowers(ids: { number })
	for _, id in ids do
		removeTower(id)
	end
end

-- Son delta'da bu kulenin (sahibi değişmeden) kaybettiği birim sayısı, yoksa 0.
function WorldView.recentDrop(id: number): number
	return drops[id] or 0
end

-- Sahip rengi (kendim / müttefik / düşman / sahipsiz).
function WorldView.ownerColor(owner: number): Color3
	return ownerColor(owner)
end

-- Seçili kuleyi vurgular (nil → seçim yok).
function WorldView.setSelected(id: number?)
	local s = getState()
	local view = if id then s.towers[id] else nil
	s.selectionTarget = if view then view.part else nil
	if view and id then
		local at = WorldView.position(id)
		-- Yolların (üstü 0,15) hemen üstünde, sahip renginde.
		s.selection.setCFrame(CFrame.new(at.X, 0.64, at.Z))
		s.selection.setColor(ownerColor(view.record.o):Lerp(Color3.new(1, 1, 1), 0.25))
		s.selection.setTransparency(0.05)
	else
		s.selection.setTransparency(1)
	end
	local previousView = if s.selected then s.towers[s.selected] else nil
	if previousView then
		previousView.label.Visible = false
	end
	if view then
		view.label.Visible = true
	end
	if view and s.selected ~= id then
		Audio.play("select")
	end
	s.selected = if view then id else nil
	for lineId in s.supplyLines do
		emphasizeSupplyLine(lineId)
	end
end

-- Bu türdeki bilinen kuleler (T tuşu, game.rs `show_similar_towers`).
function WorldView.towersOfType(towerType: number): { number }
	local s = getState()
	local list = {}
	for id, view in s.towers do
		if view.record.t == towerType then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

-- İkmal hattı olan kendi kuleleri (Shift+R ile silmek için).
function WorldView.ownSupplyLineTowers(): { number }
	local s = getState()
	local list = {}
	for id, view in s.towers do
		if view.record.o == s.me and view.record.sl ~= nil then
			table.insert(list, id)
		end
	end
	table.sort(list)
	return list
end

-- Seçim (raycast) için kule kutularının klasörü.
function WorldView.towersFolder(): Folder
	return getState().towersFolder
end

function WorldView.me(): number?
	return getState().me
end

function WorldView.record(id: number): TowerRecord?
	local view = getState().towers[id]
	return if view then view.record else nil
end

-- Oyuncu adı (birlik etiketleri için).
function WorldView.playerName(id: number): string?
	return getState().players[id]
end

-- İstemcinin bildiği kulelerle yol bulma görünümü (Sim/Pathfinding.View).
-- İttifak bilgisi yalnız benimle ilgili olanlar için var; sunucu yolu yine doğrular.
function WorldView.pathView(): any
	local s = getState()
	return {
		exists = function(id: number): boolean
			return s.towers[id] ~= nil
		end,
		owner = function(id: number): number?
			local view = s.towers[id]
			if view == nil or view.record.o == 0 then
				return nil
			end
			return view.record.o
		end,
		hasUnits = function(id: number): boolean
			local view = s.towers[id]
			if view == nil then
				return false
			end
			for _, count in view.record.u do
				if count > 0 then
					return true
				end
			end
			return false
		end,
		haveAlliance = function(a: number, b: number): boolean
			return WorldView.haveAlliance(a, b)
		end,
	}
end

-- Bilinen (görünen) tüm kule kayıtları: id → kayıt.
function WorldView.records(): { [number]: TowerRecord }
	local result = {}
	for id, view in getState().towers do
		result[id] = view.record
	end
	return result
end

-- Ekrandaki dünya noktasına en yakın bilinen kule (game.rs `get_closest`):
-- `TowerId::closest` ile en yakın ızgara kulesi, sonra onun 3×3 çevresindeki bilinen kuleler
-- arasından noktaya en yakını. Dokunmatikte kutuya tam isabet gerekmez.
function WorldView.closest(point: Vector2): number?
	local conversion = TowerId.CONVERSION
	local rx = math.floor(point.X / conversion + 0.5)
	local ry = math.floor(point.Y / conversion + 0.5)
	local maxCoord = TowerId.WORLD_SIZE - 1
	local function distanceSquared(id: number): number
		local x, y = TowerId.integerPosition(id)
		return (x - point.X) ^ 2 + (y - point.Y) ^ 2
	end
	local center: number? = nil
	local best = math.huge
	for x = math.max(rx - 1, 0), math.min(rx + 1, maxCoord) do
		for y = math.max(ry - 1, 0), math.min(ry + 1, maxCoord) do
			local id = TowerId.new(x, y)
			local d = distanceSquared(id)
			if d < best then
				center, best = id, d
			end
		end
	end
	if center == nil then
		return nil
	end
	local towers = getState().towers
	local cx, cy = TowerId.x(center), TowerId.y(center)
	local result: number? = nil
	best = math.huge
	-- `iter_towers_square(center, 1)`: y dış, x iç döngü.
	for y = math.max(cy - 1, 0), math.min(cy + 1, maxCoord) do
		for x = math.max(cx - 1, 0), math.min(cx + 1, maxCoord) do
			local id = TowerId.new(x, y)
			if towers[id] ~= nil then
				local d = distanceSquared(id)
				if d < best then
					result, best = id, d
				end
			end
		end
	end
	return result
end

-- Kendi kral kulesinin id'si (kamera için).
-- Kozmetik yayını değişti: kral taçlarını yeniden çiz (yalnız rozet; kule dokunulmaz).
Cosmetics.onChanged(function()
	local st = state
	if st == nil then
		return
	end
	for _, view in st.towers do
		if view.record.u[Unit.Ruler + 1] > 0 then
			refreshUnits(view.units, view.record, ownerColor(view.record.o))
		end
	end
end)

function WorldView.myRulerTower(): number?
	local s = getState()
	for id, view in s.towers do
		if view.record.o == s.me and view.record.u[Unit.Ruler + 1] > 0 then
			return id
		end
	end
	return nil
end

-- Model kalıpları sunucuda eşzamansız kurulur: gelen kalıpla o tipin kutularını değiştir.
task.spawn(function()
	local meshes = ReplicatedStorage:WaitForChild("TowerMeshes")
	meshes.ChildAdded:Connect(function(child)
		for _, view in getState().towers do
			if view.boxed and TowerTypeId.name(view.record.t) == child.Name then
				rebuildBody(view)
				view.part.Color = ownerColor(view.record.o)
				view.part.Transparency = if view.record.d > 0 then 0.5 else 0
			end
		end
	end)
end)

return WorldView
