--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/visible.rs

-- Görüş dışı: bulut denizi ve sınır sisi. Yalnız görsel; kural aynı (Kiomet
-- `client/src/visible.rs` `Visible::update` → bizde sunucuda `Sim/Visibility.luau`): oyuncunun her
-- kulesi `sensor_radius` içini görür, aktif olmayan (yükseltme/EMP) kule Mine'ın yarıçapıyla görür.
-- İstemci kendi kulelerini bildiği için bilinen alanı birebir hesaplar; sunucudan ek bilgi
-- gerekmez, görünmeyen hiçbir şey çizilmez (sis her hücrede, kule olsun olmasın, aynı).
--   - bilinen hücre: altında çimen diski (görünen kara); yeni açılan hücrede yavaşça belirir,
--   - bilinen alana komşu iki halka: yumuşak, süzülen sis parçacıkları (Magnific sis sprite'ı);
--     hücre görüşe girince sis incelip kaybolur,
--   - her yerin altında: yavaşça kayan bulut denizi dokusu (Magnific); harita kenarı çizgisi yok.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local TowerId = require(Sim.TowerId)
local TowerType = require(Sim.TowerType)
local TowerTypeId = require(Sim.TowerTypeId)

local Biome = require(script.Parent.Biome)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

local Fog = {}

-- Magnific görselleri (byLexum, 2026-11-05): bulut denizi (dikişsiz) ve iki sis sprite'ı
-- (siyah zeminden parlaklık = saydamlık). Kaynaklar `dist/textures/`.
local FEATHER_TEXTURES: { [string]: string } = {
	meadow = "rbxassetid://82524839778414",
	forest = "rbxassetid://71477130278882",
	desert = "rbxassetid://114712121148642",
	rocky = "rbxassetid://129763729652066",
}
local SEA_TEXTURE = "rbxassetid://121443365309454"
local WISP_TEXTURES = { "rbxassetid://78014927634100", "rbxassetid://98486230260724" }

local CELL = TowerId.CONVERSION * WorldView.STUDS_PER_UNIT
-- Görünen kara dokusu (Magnific çimen, MaterialService.CrownviaGrass ile aynı görsel).
local GRASS_TEXTURE = "rbxassetid://92047317636023"
local DESERT_TEXTURE = "rbxassetid://138401512309356"
local GRAVEL_TEXTURE = "rbxassetid://93444598545336"
local REFRESH = 0.25
local REVEAL_SECONDS = 2.5
-- Bulut denizi: kara diskinin (üstü y = 0) 0,35 altında. 0,03 farkla büyük parçalar uzaktan
-- derinlik çakışmasıyla karanın üstüne çıkıyordu; 2 stud ise ada kenarında dilimli uçurum gösterdi.
-- 2026-11-06: -0,35 → -1,5: uzak yedek zemin (FarLand) bulut denizine çok yakındı, uzakta
-- derinlik çakışmasıyla deniz zeminin üstüne çıkıp haritayı beyazlatıyordu.
local SEA_TOP = -1.5
local SEA_TILE = 2048
-- Döşeme parça boyunu tam bölmeli: yoksa 2048'lik parça sınırlarında doku kayar (düz çizgi).
local SEA_STUDS_PER_TILE = SEA_TILE / 12
local SEA_DRIFT = Vector2.new(1.4, 0.6)

type MistKind = "inner" | "outer"

type Mist = {
	anchor: Part,
	emitter: ParticleEmitter,
	kind: MistKind,
	-- Sis yoğunluğu (0..1). Açılırken 0'a iner.
	strength: NumberValue,
}

local folder: Folder? = nil
local known: { [number]: boolean } = {}
local land: { [number]: boolean } = {}
local mists: { [number]: Mist } = {}
local seaTextures: { Texture } = {}
local seaOffset = Vector2.zero
local timer = REFRESH

local function basePart(name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	return p
end

-- Bulut denizi: dünya 512 hücre; Part en fazla 2048 stud, üst yüzünde kayan doku.
local function buildSea(parent: Instance)
	local size = TowerId.WORLD_SIZE * CELL
	for x = 0, math.ceil(size / SEA_TILE) - 1 do
		for z = 0, math.ceil(size / SEA_TILE) - 1 do
			local p =
				basePart("CloudSea", Vector3.new(SEA_TILE, 0.2, SEA_TILE), Theme.colors.cloudSea)
			p.Material = Enum.Material.SmoothPlastic
			p.Position = Vector3.new(
				x * SEA_TILE + SEA_TILE / 2,
				SEA_TOP - 0.1,
				-(z * SEA_TILE + SEA_TILE / 2)
			)
			local texture = Instance.new("Texture")
			texture.Face = Enum.NormalId.Top
			texture.Texture = SEA_TEXTURE
			texture.StudsPerTileU = SEA_STUDS_PER_TILE
			texture.StudsPerTileV = SEA_STUDS_PER_TILE
			texture.Parent = p
			table.insert(seaTextures, texture)
			p.Parent = parent
		end
	end
end

local function getFolder(): Folder
	if folder == nil then
		local f = Instance.new("Folder")
		f.Name = "Fog"
		f.Parent = WorldView.towersFolder().Parent
		folder = f
		buildSea(f)
	end
	return folder :: Folder
end

-- Görünen kara: Terrain (2026-11-05, son düzen). Neden:
--   - Part karolarında malzeme dokusu her parçanın kendi köşesinden başlıyor: karo sınırlarında
--     desen kesiliyordu (çimen "kesintili"). Terrain dokusu dünyaya hizalı, dikişsiz.
--   - Terrain komşu malzemeleri kendisi yumuşakça karıştırır: bölge geçişleri (çayır/orman/çöl/
--     kayalık) yumuşak; kara kenarı da yuvarlanır.
--   - Terrain opak: zemindeki tek yarı saydam katman bölge tülü (mavi/kırmızı) kalır. Yarı saydam
--     bölge lekeleri tülü yer yer örtüyordu (Studio'da lekeler gizlenince tül kusursuz göründü).
-- Malzemeler MaterialService varyantlarıyla Magnific dokularına döner; Terrain'in kendi malzeme
-- renkleri beyaza çekilir (varsayılanlar dokuyu turuncu/koyu yeşile boyuyordu), çim süsü kapalı.
-- Hücre 4×4 bloğa bölünür; her bloğun malzemesi Biome.at (ondalıklı koordinat).
local TERRAIN_MATERIAL: { [string]: Enum.Material } = {
	meadow = Enum.Material.Grass,
	forest = Enum.Material.LeafyGrass,
	desert = Enum.Material.Sandstone,
	rocky = Enum.Material.Slate,
}

local terrainReady = false
local function setupTerrain()
	if terrainReady then
		return
	end
	terrainReady = true
	local materials = game:GetService("MaterialService")
	local overrides: { [Enum.Material]: string } = {
		[Enum.Material.Grass] = "CrownviaGrass",
		[Enum.Material.LeafyGrass] = "CrownviaForest",
		[Enum.Material.Sandstone] = "CrownviaDesert",
		[Enum.Material.Slate] = "CrownviaGravel",
	}
	for material, variant in overrides do
		if materials:FindFirstChild(variant) then
			materials:SetBaseMaterialOverride(material, variant)
		end
	end
end

-- Blok yüksekliği: 4 stud, merkez y = -4 → yüzey y ≈ 0 (Studio'da ölçüldü).
-- Zemin ızgarası 4 stud; hücre 15 stud. Her 4×4 sütun, merkezi hangi hücredeyse yalnız ona aittir
-- (2026-11-06): hizasız bloklar komşu hücrenin vokselini de değiştiriyordu → hücre silinince komşuda
-- gri delik, farklı bölgede keskin üçgen, kısmi dolulukla yamuk yüzey (bölge tülü lekeli).
local VOXEL = 4

local function fillCell(id: number, air: boolean)
	local minX = TowerId.x(id) * CELL
	local maxX = minX + CELL
	local minZ = -(TowerId.y(id) + 1) * CELL
	local maxZ = minZ + CELL
	for vx = math.ceil(minX / VOXEL - 0.5), math.floor(maxX / VOXEL - 0.5) do
		local wx = (vx + 0.5) * VOXEL
		if wx >= minX and wx < maxX then
			for vz = math.ceil(minZ / VOXEL - 0.5), math.floor(maxZ / VOXEL - 0.5) do
				local wz = (vz + 0.5) * VOXEL
				if wz >= minZ and wz < maxZ then
					local material = if air
						then Enum.Material.Air
						else TERRAIN_MATERIAL[Biome.at(wx / CELL, -wz / CELL)]
					-- Yükseklik: yüzey ≈ -0,1 (taşlık pürüzü bölge tülünün 0,42 altında kalsın).
					workspace.Terrain:FillBlock(
						CFrame.new(wx, -4.5, wz),
						Vector3.new(VOXEL, 4, VOXEL),
						material
					)
				end
			end
		end
	end
end

-- Uzak zemin: Roblox Terrain'i grafik kalitesine bağlı bir mesafeden sonra çizmez; uzaktaki
-- kuleler boşlukta kalıyordu (2026-11-06). Terrain yüzeyinin hemen altına bölge renginde düz opak
-- parça: yakında Terrain örter, uzakta bu görünür.
local FAR_COLOR: { [string]: Color3 } = {
	meadow = Color3.fromRGB(96, 150, 62),
	forest = Color3.fromRGB(62, 110, 52),
	desert = Color3.fromRGB(214, 190, 140),
	rocky = Color3.fromRGB(140, 138, 128),
}
local farParts: { [number]: Part } = {}

local function makeLand(id: number): boolean
	setupTerrain()
	fillCell(id, false)
	local cx, cy = TowerId.x(id), TowerId.y(id)
	local p =
		basePart("FarLand", Vector3.new(CELL, 0.4, CELL), FAR_COLOR[Biome.at(cx + 0.5, cy + 0.5)])
	p.Material = Enum.Material.SmoothPlastic
	p.Position = Vector3.new((cx + 0.5) * CELL, -1.05, -(cy + 0.5) * CELL)
	p.Parent = getFolder()
	farParts[id] = p
	return true
end

local function clearLand(id: number)
	fillCell(id, true)
	local p = farParts[id]
	if p then
		p:Destroy()
		farParts[id] = nil
	end
end

-- Sis saydamlığı: parçacık ömrü boyunca belirip kaybolur; `strength` genel yoğunluk.
local function mistTransparency(peak: number, strength: number): NumberSequence
	local t = 1 - (1 - peak) * strength
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, t),
		NumberSequenceKeypoint.new(0.7, t),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- Sis türleri. Görünen karanın üstünde sis yok (2026-11-05 geliştirici: fazlaydı); sis yalnız sınırda:
--   inner = görüş sınırının hemen dışı, sınır çizgisine doğru çekilmiş ince yoğun şerit: kara
--           kenarını örter,
--   outer = bir dışı: seyrek, hafif; bulut denizine geçiş.
type MistSpec = {
	height: number,
	size: NumberRange,
	rate: number,
	peak: number,
	prefill: number,
}
local MIST: { [MistKind]: MistSpec } = {
	inner = { height = 6.5, size = NumberRange.new(22, 30), rate = 0.45, peak = 0.12, prefill = 5 },
	outer = { height = 8, size = NumberRange.new(34, 44), rate = 0.18, peak = 0.42, prefill = 2 },
}

-- Hücre boyunca (kutu hacmi) yumuşak sprite'lar, yavaş dönüp süzülür. Kartlar yere paralel
-- (yukarı doğru çok yavaş hız + VelocityPerpendicular) ve kulelerin üstünde: kameraya dönük
-- kartlar zemine ve binalara gömülüp düz kesik çizgiler bırakıyordu (Roblox'ta yumuşak parçacık yok).
-- `toward`: iç halkada bilinen komşuların ortalama konumu; sis sınır çizgisine doğru çekilir.
local function makeMist(id: number, kind: MistKind, toward: Vector3?): Mist
	local spec = MIST[kind]
	local rng = Random.new(id * 7919 + 17)
	local at = WorldView.position(id)
	if toward then
		at = at:Lerp(Vector3.new(toward.X, at.Y, toward.Z), 0.3)
	end
	local box = if kind == "inner" then CELL * 0.7 else CELL * 1.1
	-- İç halkada kenar tüyü (2026-11-06 geliştirici: kara kesik bitmesin, saydamlaşarak sise karışsın):
	-- karanın kenarına oturan, merkezden dışa saydamlaşan bölge dokusu. Konum `toward` ile kara
	-- kenarına çekilir; kara kesiğini örtüp dışarı doğru söner. Bölge konumdan (bilgi sızmaz).
	local feather: Part? = nil
	if kind == "inner" and toward then
		local base = WorldView.position(id)
		-- 2026-11-06: kara kenarına ortalı ve 2,4 hücreydi; görünen hücrenin içine ~18 stud girip
		-- bölge tülünün üstüne biniyordu. Sis hücresine çekik ve küçük: içeri girdiği kısım soluk kenar.
		local edge = base:Lerp(Vector3.new(toward.X, base.Y, toward.Z), 0.3)
		local biome = Biome.at(edge.X / CELL, -edge.Z / CELL)
		local f =
			basePart("Feather", Vector3.new(CELL * 2.0, 0.05, CELL * 2.0), Color3.new(1, 1, 1))
		f.Transparency = 1
		f.CFrame = CFrame.new(edge.X, 0.05 + (id % 3) * 0.02, edge.Z)
			* CFrame.Angles(0, (id % 7) * 0.9, 0)
		local d = Instance.new("Decal")
		d.Face = Enum.NormalId.Top
		d.Texture = FEATHER_TEXTURES[biome]
		d.Parent = f
		feather = f
	end
	local anchor = basePart("Mist", Vector3.new(box, 2, box), Color3.new(1, 1, 1))
	anchor.Transparency = 1
	anchor.Position = at + Vector3.new(0, spec.height, 0)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = WISP_TEXTURES[rng:NextInteger(1, #WISP_TEXTURES)]
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	local size = rng:NextNumber(spec.size.Min, spec.size.Max)
	emitter.Size = NumberSequence.new(size * 0.85, size * 1.15)
	emitter.Lifetime = NumberRange.new(10, 14)
	emitter.Rate = spec.rate
	emitter.Speed = NumberRange.new(0.05, 0.15)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.SpreadAngle = Vector2.zero
	emitter.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-4, 4)
	emitter.Color = ColorSequence.new(Theme.colors.cloud, Theme.colors.cloudShade)
	emitter.LightEmission = 0.1
	emitter.LightInfluence = 0.6
	local strength = Instance.new("NumberValue")
	strength.Value = 1
	emitter.Transparency = mistTransparency(spec.peak, 1)
	-- Yer seviyesi bulut lekesi: kara karolarının basamaklı kenarını yerde örter ve bulut
	-- denizine yumuşakça bağlar (havadaki sis tek başına kenar çizgisini gizlemiyordu).
	-- İç halka bulutu büyük ve görünen alana doğru çekili: karo kenarı kare kesik görünmesin.
	-- 2,0'a küçültmek (2026-11-06) kara kenarındaki kare blokları açıkta bıraktı: 2,4'te kalır.
	local veilSize = CELL * (if kind == "inner" then 2.4 else 3.0)
	local veil = basePart("Veil", Vector3.new(veilSize, 0.05, veilSize), Color3.new(1, 1, 1))
	veil.Transparency = 1
	-- Yollar (üstü 0,15) ve bölge tülü üstünde; komşu lekeler aynı düzlemde titremesin.
	veil.CFrame = CFrame.new(at.X, 0.8 + (id % 4) * 0.08, at.Z)
		* CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Top
	decal.Texture = WISP_TEXTURES[rng:NextInteger(1, #WISP_TEXTURES)]
	decal.Color3 = Theme.colors.cloud
	local veilBase = if kind == "inner" then 0.02 else 0.1
	decal.Transparency = veilBase
	decal.Parent = veil
	veil.Parent = anchor
	if feather then
		feather.Parent = anchor
	end
	strength.Changed:Connect(function(value: number)
		emitter.Transparency = mistTransparency(spec.peak, value)
		decal.Transparency = 1 - (1 - veilBase) * value
	end)
	emitter.Parent = anchor
	anchor.Parent = getFolder()
	-- Sis hazır gelsin: birkaç parçacığı hemen bas.
	emitter:Emit(spec.prefill)
	return { anchor = anchor, emitter = emitter, kind = kind, strength = strength }
end

local function destroyMist(mist: Mist)
	mist.strength:Destroy()
	mist.anchor:Destroy()
end

-- Görüşe giren hücrenin sisi incelip kaybolur (canlı parçacıklar da saydamlaşır).
local function revealMist(mist: Mist)
	mist.emitter.Enabled = false
	local tween = TweenService:Create(
		mist.strength,
		TweenInfo.new(REVEAL_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
		{ Value = 0 }
	)
	tween.Completed:Connect(function()
		destroyMist(mist)
	end)
	tween:Play()
end

-- `Visibility.visibleTowers` ile aynı kural, kendi kulelerimden (hücre var mı bakmadan).
local function computeKnown(): { [number]: boolean }
	local result: { [number]: boolean } = {}
	local me = WorldView.me()
	if me == nil then
		return result
	end
	for id, record in WorldView.records() do
		if record.o == me then
			local sensorType = if record.d == 0 then record.t else TowerTypeId.Mine
			for _, seen in TowerId.iterRadius(id, TowerType.sensorRadius(sensorType)) do
				result[seen] = true
			end
		end
	end
	return result
end

local function gridNeighbors(id: number): { number }
	local x, y = TowerId.x(id), TowerId.y(id)
	local out = {}
	for dx = -1, 1 do
		for dy = -1, 1 do
			local nx, ny = x + dx, y + dy
			if
				(dx ~= 0 or dy ~= 0)
				and nx >= 0
				and ny >= 0
				and nx < TowerId.WORLD_SIZE
				and ny < TowerId.WORLD_SIZE
			then
				table.insert(out, TowerId.new(nx, ny))
			end
		end
	end
	return out
end

local function refresh()
	getFolder()
	local nextKnown = computeKnown()
	-- Halkalar: inner = bilinen alana komşu bilinmeyen hücre, outer = inner'a komşu bilinmeyen
	-- hücre. `pull`: inner hücrenin bilinen komşularının konum toplamı ve sayısı.
	local want: { [number]: MistKind } = {}
	local pull: { [number]: { sum: Vector3, count: number } } = {}
	for id in nextKnown do
		local here = WorldView.position(id)
		for _, n in gridNeighbors(id) do
			if not nextKnown[n] then
				want[n] = "inner"
				local p = pull[n]
				if p == nil then
					pull[n] = { sum = here, count = 1 }
				else
					p.sum += here
					p.count += 1
				end
			end
		end
	end
	for id, kind in table.clone(want) do
		if kind == "inner" then
			for _, n in gridNeighbors(id) do
				if not nextKnown[n] and want[n] == nil then
					want[n] = "outer"
				end
			end
		end
	end
	-- Kara: bilinen hücreler + iç sis halkası. Halkadaki kara yoğun sisin altında kalır; karanın
	-- kesik kenarı görünen alanda değil, sisin içinde biter (2026-11-06 geliştirici: kenar feather).
	-- Bilgi sızmaz: kara yalnız konumdan hesaplanan bölge rengi, kule bilgisi içermez.
	-- Kara yalnız bilinen hücreler; kenar, iç halkadaki saydamlaşan zemin lekeleriyle biter.
	local wantLand: { [number]: boolean } = nextKnown
	for id in land do
		if not wantLand[id] then
			clearLand(id)
			land[id] = nil
		end
	end
	for id in wantLand do
		if not land[id] then
			land[id] = makeLand(id)
		end
	end
	-- Sis: türü değişen ya da artık gerekmeyen hücrenin sisi incelip kaybolur (görüşe giren hücre
	-- dahil); gereken türde yenisi belirir.
	for id, mist in mists do
		if want[id] ~= mist.kind then
			revealMist(mist)
			mists[id] = nil
		end
	end
	for id, kind in want do
		if not mists[id] then
			local p = pull[id]
			mists[id] = makeMist(id, kind :: MistKind, if p then p.sum / p.count else nil)
		end
	end
	known = nextKnown
end

function Fog.update(dt: number)
	-- Bulut denizi her karede yavaşça kayar.
	seaOffset = Vector2.new(
		(seaOffset.X + SEA_DRIFT.X * dt) % SEA_STUDS_PER_TILE,
		(seaOffset.Y + SEA_DRIFT.Y * dt) % SEA_STUDS_PER_TILE
	)
	for _, texture in seaTextures do
		texture.OffsetStudsU = seaOffset.X
		texture.OffsetStudsV = seaOffset.Y
	end
	timer += dt
	if timer < REFRESH then
		return
	end
	timer = 0
	refresh()
end

-- Önden yüklenecek görseller (giriş ekranındayken; ilk görüşte geç gelmesin).
Fog.ASSETS = {
	SEA_TEXTURE,
	GRASS_TEXTURE,
	WISP_TEXTURES[1],
	WISP_TEXTURES[2],
	DESERT_TEXTURE,
	GRAVEL_TEXTURE,
}

-- Bilinen hücre mi (görünen kara).
function Fog.isKnown(id: number): boolean
	return known[id] == true
end

function Fog.clear()
	for id in land do
		clearLand(id)
		land[id] = nil
	end
	for id, mist in mists do
		destroyMist(mist)
		mists[id] = nil
	end
	table.clear(known)
	timer = REFRESH
end

return Fog
