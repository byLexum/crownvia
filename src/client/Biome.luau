--!strict
-- Görsel bölgeler: çayır, orman, çöl, kayalık. YALNIZ GÖRSEL; kaynakta arazi türü yok ve kural
-- etkisi sıfır (hız, görüş, savaş aynı). Hücre koordinatından deterministik: her istemcide aynı,
-- kule olup olmamasından bağımsız (görünmeyen kule hakkında bilgi vermez).
-- Bölgeler 10–15 hücre genişliğinde; iki düşük frekanslı değer gürültüsü (nem, yükseklik).

local RunService = game:GetService("RunService")

local Biome = {}

export type Kind = "meadow" | "forest" | "desert" | "rocky"

-- Hücre köşesi için deterministik [0, 1) değer (tamsayı karma, 32 bit).
local function hash(x: number, y: number, seed: number): number
	local h = bit32.bxor(x * 374761393, y * 668265263, seed * 2246822519)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = bit32.band(h * 1274126177, 0xFFFFFFFF)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / 4294967296
end

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

-- Değer gürültüsü: `scale` hücrede bir köşe, aradaki değer yumuşak ara değer.
local function valueNoise(x: number, y: number, scale: number, seed: number): number
	local fx, fy = x / scale, y / scale
	local ix, iy = math.floor(fx), math.floor(fy)
	local tx, ty = smooth(fx - ix), smooth(fy - iy)
	local a = hash(ix, iy, seed)
	local b = hash(ix + 1, iy, seed)
	local c = hash(ix, iy + 1, seed)
	local d = hash(ix + 1, iy + 1, seed)
	local top = a + (b - a) * tx
	local bottom = c + (d - c) * tx
	return top + (bottom - top) * ty
end

-- Sürekli alanlar (nem, yükseklik) [0, 1); ondalıklı ızgara koordinatı kabul eder (zemin geçişi).
function Biome.fields(x: number, y: number): (number, number)
	if RunService:IsStudio() then
		local override = workspace:GetAttribute("BiomeOverride")
		if override == "forest" then
			return 0.9, 0.3
		elseif override == "desert" then
			return 0.1, 0.3
		elseif override == "rocky" then
			return 0.5, 0.95
		elseif override == "meadow" then
			return 0.5, 0.3
		end
	end
	local wet = 0.7 * valueNoise(x, y, 14, 1) + 0.3 * valueNoise(x, y, 5, 2)
	local high = 0.7 * valueNoise(x, y, 17, 3) + 0.3 * valueNoise(x, y, 6, 4)
	return wet, high
end

-- Hücre (ızgara x, y) → bölge. Çayır en sık; çöl kuru ve alçak, orman nemli, kayalık yüksek.
-- Eşikler 193×193 hücrede ölçüldü (2026-11-05): çayır %44, orman %23, çöl %21, kayalık %12.
-- Yalnız Studio: `workspace` üzerindeki `BiomeOverride` özelliği tüm haritayı o bölge yapar (test).
function Biome.at(x: number, y: number): Kind
	if RunService:IsStudio() then
		local override = workspace:GetAttribute("BiomeOverride")
		if
			override == "meadow"
			or override == "forest"
			or override == "desert"
			or override == "rocky"
		then
			return override
		end
	end
	-- Koordinat bükme (domain warp, 2026-11-05): zemin 4 studluk bloklarla çizilir; geniş ölçekli
	-- gürültüde sınır ızgaraya paralel giden yerlerde 30–40 studluk dümdüz "kutu" kenarı çıkıyordu.
	-- Üç küçük ölçekli kaydırma (4 / 2 / 1 hücre dalga boyu) sınırı kırar; bölge oranları değişmez.
	-- Ölçüm (160×160 hücre, 4 studluk blok): ≥8 blok düz giden sınır payı %16,5 → %5,1, en uzun düz
	-- parça 128 → 64 stud. Kalan düz parçalar ızgaranın kendisinden. Deterministik: her istemcide aynı.
	local wx = x
		+ 2.4 * (valueNoise(x, y, 4, 9) - 0.5)
		+ 1.6 * (valueNoise(x, y, 2, 5) - 0.5)
		+ 1.0 * (valueNoise(x, y, 1, 7) - 0.5)
	local wy = y
		+ 2.4 * (valueNoise(x, y, 4, 10) - 0.5)
		+ 1.6 * (valueNoise(x, y, 2, 6) - 0.5)
		+ 1.0 * (valueNoise(x, y, 1, 8) - 0.5)
	local wet, high = Biome.fields(wx, wy)
	if high > 0.72 then
		return "rocky"
	elseif wet > 0.6 then
		return "forest"
	elseif wet < 0.38 and high < 0.62 then
		return "desert"
	end
	return "meadow"
end

-- Zemin lekesi dokuları (Magnific doku + yumuşak alfa maskesi, byLexum 2026-11-05;
-- kaynak `dist/textures/`). Çayırın lekesi yok (çimen dokusu kendisi).
Biome.PATCHES = {
	desert = { "rbxassetid://75429519497950", "rbxassetid://79654667835255" },
	-- Orman: çimen dokusunun koyu, serin tonu (resimli çalı dokusu sahte duruyordu; ormanı 3D
	-- çamlar yapar). Kayalık: çakıl dokusu yarı ölçekte ve düşük kontrastta.
	forest = { "rbxassetid://94617827867255", "rbxassetid://88119635557136" },
	rocky = { "rbxassetid://83637622744472", "rbxassetid://100666234302206" },
} :: { [string]: { string } }

return Biome
