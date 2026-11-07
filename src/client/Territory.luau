--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/territory.rs, client/src/shaders/background.frag, client/src/game.rs

-- Bölge görünümü. Kaynakta zemin bir shader'la çizilir: her nokta en yakın kulenin sahibinin
-- rengini alır (Voronoi), farklı sahipler arasında parlak sınır, koyu "midnight" zemin. Roblox'ta
-- shader yok; parçalarla yaklaşık karşılık (CLAUDE.md kural 5, ölçmeden EditableMesh yok):
--   - sahipli her kulenin Voronoi hücresi (8 komşunun orta dikmeleriyle kırpılmış kare), sahip
--     renginde yarı saydam dolgu (WedgePart üçgenleri),
--   - hücre kenarını üreten komşunun sahibi farklıysa o kenar boyunca sahip renginde sınır,
--   - `Territories::update`: oyuncu başına kütle merkezine en yakın kulede ad; yazı boyu
--     `min(zoom × 0.05, √(kule sayısı × CONVERSION²) × 0.5)`, kendi adı yalnız `zoom > 30`.
-- Renkler `shieldColor` karşılığı: kendim mavi, müttefik mor, düşman kırmızı (Theme).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TowerId =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"):WaitForChild("TowerId"))

local Biome = require(script.Parent.Biome)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

local Territory = {}

local STUDS = WorldView.STUDS_PER_UNIT
local CELL = TowerId.CONVERSION * STUDS
local BORDER_THICKNESS = 0.35
-- Bölge tülü: bölge lekelerinin (0,08–0,24) üstünde (katmanlar: WorldView.ROAD_Y yorumu).
local GROUND_Y = 0.42
-- Sınır çizgisi orta dikmeden bu kadar kendi kulesine kayar: iki taraf yan yana kendi rengini çizer.
local BORDER_SHIFT = 0.3
-- Sınır çizgisi: bundan kısa kenarlar birleştirilir, köşe uzantısı en fazla bu kadar (stud).
local MIN_BORDER_EDGE = 1.5
local MAX_MITER = 1.25
local NAME_REFRESH = 0.5
-- 2026-11-05: kırmızı tül yeşil çimenin üstünde hangi tonda olursa olsun kahverengiye döner;
-- tül hafif kalır, sahipliği sınır çizgisi ve kule rozeti taşır.
local FILL_TRANSPARENCY = 0.62

type Cell = { disc: Part?, borders: { BasePart } }

local folder: Folder? = nil
local cells: { [number]: Cell } = {}
local dirty: { [number]: boolean } = {}
local names: { [number]: { anchor: Part, gui: BillboardGui, label: TextLabel, count: number } } = {}
local nameTimer = 0
-- Kule başına süs (ağaç, kaya): kule görünürken bir kez kurulur, sahip değişince dokunulmaz.
local decor: { [number]: { BasePart } } = {}
local lowGraphics = false

local function getFolder(): Folder
	if folder == nil then
		local f = Instance.new("Folder")
		f.Name = "Territory"
		f.Parent = WorldView.towersFolder().Parent
		folder = f
		-- Kaynaktaki koyu zemin ("midnight"): dünya 512 hücre; Part en fazla 2048 stud.
		local size = TowerId.WORLD_SIZE * CELL
		local tile = 2048
		for x = 0, math.ceil(size / tile) - 1 do
			for z = 0, math.ceil(size / tile) - 1 do
				local ground = Instance.new("Part")
				ground.Name = "Ground"
				ground.Anchored = true
				ground.CanCollide = false
				ground.CanQuery = false
				ground.CanTouch = false
				ground.CastShadow = false
				-- Görüş dışı: bulut denizi tabanı (Fog.luau sınırda bulut kümeleri çizer).
				ground.Material = Enum.Material.SmoothPlastic
				ground.Color = Theme.colors.cloudSea
				ground.Size = Vector3.new(tile, 1, tile)
				ground.Position = Vector3.new(x * tile + tile / 2, -4, -(z * tile + tile / 2))
				ground.Parent = f
			end
		end
	end
	return folder :: Folder
end

local function flatPart(name: string, size: Vector3, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Size = size
	p.Color = color
	p.Transparency = transparency
	return p
end

local function clearCell(id: number)
	local cell = cells[id]
	if cell == nil then
		return
	end
	if cell.disc then
		cell.disc:Destroy()
	end
	for _, b in cell.borders do
		b:Destroy()
	end
	cells[id] = nil
end

-- 8 komşu (shader 3×3 hücreye bakar).
local function gridNeighbors(id: number): { number }
	local x, y = TowerId.x(id), TowerId.y(id)
	local result = {}
	for dx = -1, 1 do
		for dy = -1, 1 do
			if dx ~= 0 or dy ~= 0 then
				local nx, ny = x + dx, y + dy
				if nx >= 0 and ny >= 0 and nx < TowerId.WORLD_SIZE and ny < TowerId.WORLD_SIZE then
					table.insert(result, TowerId.new(nx, ny))
				end
			end
		end
	end
	return result
end

type Vertex = { p: Vector2, edge: number }

-- Sutherland–Hodgman: `p`'den `q`'ya yakın yarı düzlemle kırp (orta dikme). Her köşe kendisinden
-- çıkan kenarın kaynağını (`edge` = komşu kule kimliği, 0 = sınırsız kare) taşır.
local function clip(poly: { Vertex }, p: Vector2, q: Vector2, edge: number): { Vertex }
	local normal = q - p
	local mid = (p + q) * 0.5
	local function inside(v: Vector2): boolean
		return (v - mid):Dot(normal) <= 0
	end
	local function intersect(a: Vector2, b: Vector2): Vector2
		local da = (a - mid):Dot(normal)
		local db = (b - mid):Dot(normal)
		return a + (b - a) * (da / (da - db))
	end
	local out: { Vertex } = {}
	for i, cur in poly do
		local nxt = poly[i % #poly + 1]
		local inCur, inNxt = inside(cur.p), inside(nxt.p)
		if inCur and inNxt then
			table.insert(out, cur)
		elseif inCur then
			table.insert(out, cur)
			table.insert(out, { p = intersect(cur.p, nxt.p), edge = edge })
		elseif inNxt then
			table.insert(out, { p = intersect(cur.p, nxt.p), edge = cur.edge })
		end
	end
	return out
end

-- Üçgeni iki WedgePart ile çiz (yatay, ince).
local function triangle(
	parent: Instance,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	color: Color3,
	parts: { BasePart },
	transparency: number
)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	if ac:Cross(ab).Magnitude < 1e-4 then
		return
	end
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	for side = 1, 2 do
		local w = Instance.new("WedgePart")
		w.Name = "Fill"
		w.Anchored = true
		w.CanCollide = false
		w.CanQuery = false
		w.CanTouch = false
		w.CastShadow = false
		w.Material = Enum.Material.SmoothPlastic
		w.Color = color
		w.Transparency = transparency
		if side == 1 then
			w.Size = Vector3.new(0.002, height, math.abs(ab:Dot(back)))
			w.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
		else
			w.Size = Vector3.new(0.002, height, math.abs(ac:Dot(back)))
			w.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
		end
		w.Parent = parent
		table.insert(parts, w)
	end
end

local function clearDecor(id: number)
	local parts = decor[id]
	if parts then
		for _, p in parts do
			p:Destroy()
		end
		decor[id] = nil
	end
end

local function prop(
	parent: Instance,
	parts: { BasePart },
	shape: Enum.PartType,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local p = flatPart("Decor", size, color, 0)
	p.Shape = shape
	p.Material = material
	p.CastShadow = true
	p.CFrame = cframe
	p.Parent = parent
	table.insert(parts, p)
	return p
end

-- Katmanlı çam: gövde + üç daralan kat (ilkel parça; model gelince yerini alır).
local function pine(parent: Instance, parts: { BasePart }, at: Vector3, scale: number, rng: Random)
	local trunk = 0.5 * scale
	prop(
		parent,
		parts,
		Enum.PartType.Cylinder,
		Vector3.new(trunk, 0.3 * scale, 0.3 * scale),
		CFrame.new(at + Vector3.new(0, trunk / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Theme.colors.trunk,
		Enum.Material.Wood
	)
	local color = if rng:NextNumber() < 0.5 then Theme.colors.pine else Theme.colors.pineLight
	local y = trunk
	for tier = 1, 3 do
		local width = (1.9 - tier * 0.45) * scale
		local height = 0.75 * scale
		prop(
			parent,
			parts,
			Enum.PartType.Cylinder,
			Vector3.new(height, width, width),
			CFrame.new(at + Vector3.new(0, y + height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			color,
			Enum.Material.SmoothPlastic
		)
		y += height * 0.72
	end
end

-- Kaya grubu: yarı gömülü, eğik 2–3 blok.
local function rocks(parent: Instance, parts: { BasePart }, at: Vector3, scale: number, rng: Random)
	for i = 1, rng:NextInteger(2, 3) do
		local s = rng:NextNumber(0.6, 1.3) * scale * (if i == 1 then 1.3 else 1)
		local offset = Vector3.new(rng:NextNumber(-0.9, 0.9), 0, rng:NextNumber(-0.9, 0.9)) * scale
		prop(
			parent,
			parts,
			Enum.PartType.Block,
			Vector3.new(s * 1.2, s * 0.9, s),
			CFrame.new(at + offset + Vector3.new(0, s * 0.18, 0))
				* CFrame.Angles(
					rng:NextNumber(-0.35, 0.35),
					rng:NextNumber() * math.pi,
					rng:NextNumber(-0.35, 0.35)
				),
			Theme.colors.rockWarm,
			Enum.Material.Rock
		)
	end
end

-- Süs: yalnız görsel (kural yok). Kule kimliğinden tohumlu, her istemcide aynı yerleşim.
-- Yalnız görünen kulelerin çevresinde kurulur (görüş dışına bilgi sızmaz).
-- Yollardan (kule ile yol komşuları arası doğru parçaları) ve kulelerden uzak durur.
local function ensureDecor(id: number, parent: Instance)
	if decor[id] then
		return
	end
	-- Düşük grafik (Ayarlar): süs çizilmez, zayıf telefonlarda parça sayısı düşer.
	if lowGraphics then
		decor[id] = {}
		return
	end
	local parts: { BasePart } = {}
	decor[id] = parts
	local rng = Random.new(id)
	local here = WorldView.position(id)
	-- 2026-11-05: renk lekeleri kaldırıldı (çimen dokusunun üstünde sert daire gibi duruyordu).
	local others = {}
	for _, n in TowerId.neighbors(id) do
		table.insert(others, WorldView.position(n))
	end
	-- Yol bağlantısı olmayan yan hücrelerde de bina olabilir: 8 ızgara komşusunun hepsinden uzak dur
	-- (her hücrede aynı kontrol; görünmeyen kule hakkında bilgi vermez).
	local nearby = {}
	for _, n in gridNeighbors(id) do
		table.insert(nearby, WorldView.position(n))
	end
	local function clear(p: Vector3, road: number): boolean
		if (Vector3.new(p.X - here.X, 0, p.Z - here.Z)).Magnitude < 4.2 then
			return false
		end
		for _, there in nearby do
			if (Vector3.new(p.X - there.X, 0, p.Z - there.Z)).Magnitude < 6 then
				return false
			end
		end
		for _, there in others do
			local seg = there - here
			local t = math.clamp((p - here):Dot(seg) / math.max(seg:Dot(seg), 1e-3), 0, 1)
			local closest = here + seg * t
			if (Vector3.new(p.X - closest.X, 0, p.Z - closest.Z)).Magnitude < road then
				return false
			end
			if (Vector3.new(p.X - there.X, 0, p.Z - there.Z)).Magnitude < 5 then
				return false
			end
		end
		return true
	end
	local meshes = ReplicatedStorage:FindFirstChild("PropMeshes")
	-- İçe aktarılmış süs modelini yerleştir (yoksa false döner; çağıran ilkel yedeğe düşer).
	local function placeMesh(name: string, at: Vector3, scale: number): boolean
		local template = if meshes then meshes:FindFirstChild(name) else nil
		if not (template and template:IsA("MeshPart")) then
			return false
		end
		local p = template:Clone()
		p.Size = p.Size * scale
		p.CFrame = CFrame.new(at + Vector3.new(0, p.Size.Y / 2, 0))
			* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
		p.Parent = parent
		table.insert(parts, p)
		return true
	end
	local cellX, cellY = TowerId.x(id), TowerId.y(id)
	local biome = Biome.at(cellX, cellY)
	-- Bölge zemini opak karolarda (Fog.luau); yarı saydam leke yok (bölge tülünü örtüyordu).
	-- Süs: bölgeye göre küme sayısı ve türleri.
	type Pick = { name: string, weight: number }
	local picks: { Pick }
	local clusters: number
	if biome == "forest" then
		picks = {
			{ name = "Pines", weight = 8 },
			{ name = "Pine", weight = 3 },
			{ name = "Rocks", weight = 1 },
		}
		-- Yoğun orman: 3D çam kümeleri (zemin yalnız koyu çimen tonu).
		-- 2026-11-05: 7–10 küme Studio'yu çökertti; 4–6.
		clusters = rng:NextInteger(4, 6)
	elseif biome == "desert" then
		picks = {
			{ name = "DeadTree", weight = 4 },
			{ name = "Rocks", weight = 3 },
			{ name = "Pumpjack", weight = 2 },
			{ name = "Wreck", weight = 1 },
		}
		clusters = rng:NextInteger(1, 3)
	elseif biome == "rocky" then
		picks = {
			{ name = "Rocks", weight = 6 },
			{ name = "Pine", weight = 2 },
			{ name = "DeadTree", weight = 1 },
		}
		clusters = rng:NextInteger(2, 4)
	else
		picks = {
			{ name = "Pines", weight = 3 },
			{ name = "Pine", weight = 4 },
			{ name = "Rocks", weight = 2 },
			{ name = "Fence", weight = 1 },
		}
		clusters = rng:NextInteger(2, 4)
	end
	local total = 0
	for _, pick in picks do
		total += pick.weight
	end
	for _ = 1, clusters do
		local angle = rng:NextNumber() * math.pi * 2
		local radius = rng:NextNumber(5.5, 8)
		local center = here + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local scale = rng:NextNumber(0.8, 1.2)
		local roll = rng:NextNumber() * total
		local name = picks[#picks].name
		for _, pick in picks do
			roll -= pick.weight
			if roll <= 0 then
				name = pick.name
				break
			end
		end
		if clear(center, 2.2) and not placeMesh(name, center, scale) then
			-- Model yoksa ilkel yedek yalnız ağaç ve kaya için (diğer süsler model gelince çıkar).
			if name == "Pines" or name == "Pine" then
				for _ = 1, if name == "Pines" then 3 else rng:NextInteger(1, 2) do
					local at = center
						+ Vector3.new(rng:NextNumber(-1.4, 1.4), 0, rng:NextNumber(-1.4, 1.4))
					if clear(at, 2.0) then
						pine(parent, parts, at, scale * rng:NextNumber(0.8, 1.15), rng)
					end
				end
			elseif name == "Rocks" then
				rocks(parent, parts, center, scale, rng)
			end
		end
	end
	-- Kule çevresi: sandık/varil yığını (askeri ikmal hissi), modeli varsa.
	if rng:NextNumber() < 0.4 then
		local angle = rng:NextNumber() * math.pi * 2
		local at = here + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 4.9
		if clear(at, 1.8) then
			placeMesh("Crates", at, rng:NextNumber(0.85, 1.1))
		end
	end
	-- Bazı kulelerin önünde kum torbası yayı (askeri minyatür hissi).
	if rng:NextNumber() < 0.3 then
		local angle = rng:NextNumber() * math.pi * 2
		for step = -2, 2 do
			local a = angle + step * 0.22
			local at = here + Vector3.new(math.cos(a), 0, math.sin(a)) * 4.8
			if clear(at, 1.6) then
				prop(
					parent,
					parts,
					Enum.PartType.Block,
					Vector3.new(0.95, 0.4, 0.5),
					CFrame.lookAt(at + Vector3.new(0, 0.2, 0), here + Vector3.new(0, 0.2, 0)),
					Theme.colors.sandbag,
					Enum.Material.Fabric
				)
			end
		end
	end
end

-- İki doğrunun kesişimi (`p1 + d1·t` ile `p2 + d2·u`); paralelse nil.
local function lineIntersect(p1: Vector2, d1: Vector2, p2: Vector2, d2: Vector2): Vector2?
	local denom = d1.X * d2.Y - d1.Y * d2.X
	if math.abs(denom) < 1e-4 then
		return nil
	end
	local diff = p2 - p1
	local t = (diff.X * d2.Y - diff.Y * d2.X) / denom
	return p1 + d1 * t
end

-- Sınır çizgileri (2026-11-06 düzeltme): önceki sürüm her kenarı kule yönünde (kenara dik olmayan)
-- kaydırıyordu, komşu kenarların çizgileri köşede buluşmuyor, kopukluk ve basamak kalıyordu.
-- Şimdi her kenar kendi iç normali boyunca `BORDER_SHIFT` kayar; uçlar komşu kenarla buluşur:
-- komşu kenar da sınırsa kayık çizgilerin kesişimi (miter), değilse (aynı sahipli komşu hücre)
-- komşu kenarın gerçek doğrusu ile kesişim, böylece çizgi hücre geçişinde kesilmez.
-- Çokgen saat yönünün tersi (Voronoi hücresi, dışbükey): sol taraf içeridir.
local function drawBorders(
	parent: Instance,
	parts: { BasePart },
	poly: { Vertex },
	owner: number,
	color: Color3
)
	-- Sıfır uzunluklu kenarları ele (yön hesabı bozulmasın).
	local clean: { Vertex } = {}
	for i, v in poly do
		local w = poly[i % #poly + 1]
		if (w.p - v.p).Magnitude > 1e-3 then
			table.insert(clean, v)
		end
	end
	-- Çok kısa kenarlar (dört hücrenin neredeyse tek noktada buluştuğu Voronoi köşeleri) çizgide
	-- dik çıkıntı bırakıyordu: iki ucu orta noktada birleştir (çıkan kenar `w.edge`, giren kenar kalır).
	local merged = true
	while merged and #clean > 3 do
		merged = false
		for i, v in clean do
			local nextIndex = i % #clean + 1
			local w = clean[nextIndex]
			if (w.p - v.p).Magnitude < MIN_BORDER_EDGE then
				clean[i] = { p = (v.p + w.p) * 0.5, edge = w.edge }
				table.remove(clean, nextIndex)
				merged = true
				break
			end
		end
	end
	local count = #clean
	if count < 3 then
		return
	end
	local dirs: { Vector2 } = {}
	local normals: { Vector2 } = {}
	local isBorder: { boolean } = {}
	for i, v in clean do
		local w = clean[i % count + 1]
		local d = (w.p - v.p).Unit
		dirs[i] = d
		normals[i] = Vector2.new(-d.Y, d.X)
		-- Bu kenarı üreten komşunun sahibi farklıysa sınır. Görünmeyen komşuya (sis) bakan kenar da
		-- sınırdır: yoksa çizgi sis tarafında kopuyor, bölge açık kalıyordu.
		local other = if v.edge ~= 0 then WorldView.record(v.edge) else nil
		isBorder[i] = other == nil or other.o ~= owner
	end
	local shift = BORDER_SHIFT
	local lineColor = color:Lerp(Color3.new(1, 1, 1), 0.35)
	for i, v in clean do
		if isBorder[i] then
			local w = clean[i % count + 1]
			local prev = (i - 2) % count + 1
			local nextIndex = i % count + 1
			local d, n = dirs[i], normals[i]
			local function endPoint(vertex: Vector2, other: number): Vector2
				local fallback = vertex + n * shift
				local onOther = if isBorder[other] then vertex + normals[other] * shift else vertex
				local hit = lineIntersect(vertex + n * shift, d, onOther, dirs[other])
				-- Çok sivri açıda kesişim uzağa kaçar: kayık köşeye dön.
				if hit == nil or (hit - vertex).Magnitude > MAX_MITER then
					return fallback
				end
				return hit
			end
			local p0 = endPoint(v.p, prev)
			local p1 = endPoint(w.p, nextIndex)
			local length = (p1 - p0).Magnitude
			if length > 0.05 then
				local mid = (p0 + p1) * 0.5
				local bar = flatPart(
					"Border",
					Vector3.new(BORDER_THICKNESS, 0.1, length + BORDER_THICKNESS),
					color,
					0
				)
				bar.Color = lineColor
				local from = Vector3.new(mid.X, GROUND_Y + 0.08, mid.Y)
				bar.CFrame = CFrame.lookAt(from, from + Vector3.new(p1.X - p0.X, 0, p1.Y - p0.Y))
				bar.Parent = parent
				table.insert(parts, bar)
			end
		end
	end
end

local function rebuildCell(id: number)
	clearCell(id)
	local record = WorldView.record(id)
	if record == nil then
		clearDecor(id)
		return
	end
	local parent = getFolder()
	ensureDecor(id, parent)
	local owned = record.o ~= 0
	local color = WorldView.ownerColor(record.o)
	local here3 = WorldView.position(id)
	local here = Vector2.new(here3.X, here3.Z)
	-- Hücre: kule çevresinde kare, 8 ızgara komşusunun orta dikmeleriyle kırpılır (Voronoi).
	-- Görünmeyen komşular da kırpar (2026-11-06): konum kimlikten deterministik
	-- (`TowerId.integerPosition`), görüş dışı hakkında bilgi vermez. Önceden yalnız görünen komşular
	-- kırpıyordu; görünmeyen yönde 2 hücrelik kare kalıyor → sise taşan testere dişi uçlar, komşu
	-- tüllerin üst üste binmesi (koyu üçgen) ve sise uzanan sınır çizgileri.
	local r = CELL
	-- Dolgu ve sınır AYNI çokgeni kullanır (2026-11-06): gerçek orta dikmeler, sis tarafında da.
	-- Sisin yanında tülü içeri çekmek (FOG_INSET) her hücrede farklı yere düşüyordu: komşu hücrelerin
	-- tülü ve sınırı köşede tutmuyor, sınır çizgisinde basamak ve tülde üçgen çentik çıkıyordu.
	-- Gerçek Voronoi kenarları komşu hücrelerle köşede birebir buluşur.
	local poly: { Vertex } = {
		{ p = here + Vector2.new(-r, -r), edge = 0 },
		{ p = here + Vector2.new(r, -r), edge = 0 },
		{ p = here + Vector2.new(r, r), edge = 0 },
		{ p = here + Vector2.new(-r, r), edge = 0 },
	}
	for _, n in gridNeighbors(id) do
		local there = WorldView.position(n)
		poly = clip(poly, here, Vector2.new(there.X, there.Z), n)
	end
	local parts: { BasePart } = {}
	-- Sahipli hücre: çimenin üstünde sahip renginde açık, yarı saydam tül (hedef görünüm B).
	-- Tek renk her bölgede (2026-11-06): hücreye göre ton farkı başka oyuncu gibi görünüyordu.
	-- Orta doygunluk: çimende de kumda da mavi kalır.
	local h, sat = color:ToHSV()
	local fill = Color3.fromHSV(h, math.min(sat * 1.15, 1), 0.97)
	local center = Vector3.new(here.X, GROUND_Y, here.Y)
	for i, v in poly do
		local w = poly[i % #poly + 1]
		local a = Vector3.new(v.p.X, GROUND_Y, v.p.Y)
		local b = Vector3.new(w.p.X, GROUND_Y, w.p.Y)
		if owned then
			triangle(parent, center, a, b, fill, parts, FILL_TRANSPARENCY)
		end
	end
	if owned then
		drawBorders(parent, parts, poly, record.o, color)
	end
	cells[id] = { disc = nil, borders = parts }
end

-- WorldView her kule değişiminde çağırır (sahip, görünürlük, ittifak rengi).
function Territory.markDirty(id: number)
	dirty[id] = true
	for _, n in gridNeighbors(id) do
		dirty[n] = true
	end
end

function Territory.markAllDirty()
	for id in WorldView.records() do
		dirty[id] = true
	end
	for id in cells do
		dirty[id] = true
	end
end

local function updateNames(zoom: number)
	local me = WorldView.me()
	local groups: { [number]: { sum: Vector3, count: number, ids: { number } } } = {}
	for id, record in WorldView.records() do
		if record.o ~= 0 then
			local g = groups[record.o]
			if g == nil then
				g = { sum = Vector3.zero, count = 0, ids = {} }
				groups[record.o] = g
			end
			g.sum += WorldView.position(id)
			g.count += 1
			table.insert(g.ids, id)
		end
	end
	local parent = getFolder()
	for owner, entry in names do
		if groups[owner] == nil then
			entry.anchor:Destroy()
			names[owner] = nil
		end
	end
	for owner, g in groups do
		local center = g.sum / g.count
		-- Kütle merkezine en yakın kule (`best_tower_id`).
		local best, bestDistance = g.ids[1], math.huge
		for _, id in g.ids do
			local d = (WorldView.position(id) - center).Magnitude
			if d < bestDistance or (d == bestDistance and id < best) then
				best, bestDistance = id, d
			end
		end
		local entry = names[owner]
		if entry == nil then
			local anchor = flatPart("Name", Vector3.one, Color3.new(), 1)
			anchor.Parent = parent
			local gui = Instance.new("BillboardGui")
			gui.LightInfluence = 0
			gui.Parent = anchor
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.TextScaled = true
			label.FontFace = Theme.fonts.heading
			label.TextStrokeTransparency = 0.6
			label.Parent = gui
			entry = { anchor = anchor, gui = gui, label = label, count = 0 }
			names[owner] = entry
		end
		local e = entry :: { anchor: Part, gui: BillboardGui, label: TextLabel, count: number }
		e.count = g.count
		e.anchor.Position = WorldView.position(best) + Vector3.new(0, 6, 0)
		local isMe = owner == me
		e.label.Text = WorldView.playerName(owner) or ""
		e.label.TextColor3 = if isMe
			then Color3.new(0.88, 0.88, 0.88)
			else Color3.new(0.67, 0.67, 0.67)
		-- Yazı boyu dünya biriminde → stud.
		local maxHeight = math.sqrt(g.count * TowerId.CONVERSION ^ 2) * 0.5
		local height = math.min(zoom * 0.05, maxHeight) * STUDS
		local width = height * math.max(#e.label.Text, 1) * 0.62
		e.gui.Size = UDim2.fromScale(width, height)
		e.gui.Enabled = (not isMe or zoom > 30) and height > 0.5
	end
end

-- Her kare: kirli kuleleri yeniden çiz, adları yarım saniyede bir güncelle.
-- `zoom`: kameranın gördüğü dünya genişliği (Camera.zoom, kaynaktaki zoom).
function Territory.update(dt: number, zoom: number)
	if next(dirty) ~= nil then
		local batch = dirty
		dirty = {}
		for id in batch do
			rebuildCell(id)
		end
	end
	nameTimer += dt
	if nameTimer >= NAME_REFRESH then
		nameTimer = 0
		updateNames(zoom)
	end
end

-- Ayarlar: düşük grafik açılınca mevcut süsler silinir, kapanınca yeniden kurulur.
function Territory.setLowGraphics(low: boolean)
	if lowGraphics == low then
		return
	end
	lowGraphics = low
	for id in decor do
		clearDecor(id)
		dirty[id] = true
	end
end

-- Süs modelleri sunucuda eşzamansız kurulur: gelince süsleri yeniden yerleştir.
task.spawn(function()
	local meshes = ReplicatedStorage:WaitForChild("PropMeshes")
	meshes.ChildAdded:Connect(function()
		for id in decor do
			clearDecor(id)
			dirty[id] = true
		end
	end)
end)

function Territory.clear()
	for id in decor do
		clearDecor(id)
	end
	for id in cells do
		clearCell(id)
	end
	for owner, entry in names do
		entry.anchor:Destroy()
		names[owner] = nil
	end
	table.clear(dirty)
end

return Territory
