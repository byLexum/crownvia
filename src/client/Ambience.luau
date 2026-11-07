--!strict
-- Görsel atmosfer (hedef görünüm B, yalnız istemci; kuralla ilgisi yok):
--   - Atmosphere: ufka doğru açık mavi pus,
--   - Bloom: hafif ışık parlaması (neon sınırlar, efektler),
--   - ColorCorrection: biraz daha canlı renk,
--   - DepthOfField: minyatür (tilt-shift) hissi; netlik her karede kameranın baktığı yere ayarlanır.

local Lighting = game:GetService("Lighting")

local Ambience = {}

local depth: DepthOfFieldEffect? = nil

local function effect<T>(className: string, name: string): T
	local existing = Lighting:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local e = Instance.new(className :: any)
	e.Name = name
	e.Parent = Lighting
	return e :: any
end

function Ambience.init()
	local atmosphere: Atmosphere = effect("Atmosphere", "CrownviaAtmosphere")
	-- 2026-11-06: 0,28 uzakta (haritanın üstü) çimeni beyaza boğuyordu.
	atmosphere.Density = 0.16
	atmosphere.Offset = 0.1
	atmosphere.Color = Color3.fromRGB(205, 222, 238)
	atmosphere.Decay = Color3.fromRGB(150, 175, 200)
	atmosphere.Glare = 0
	atmosphere.Haze = 0.5

	local bloom: BloomEffect = effect("BloomEffect", "CrownviaBloom")
	-- 2026-11-04: oyun haritası okunmalı; bloom ve tilt-shift hafifletildi.
	bloom.Intensity = 0.1
	bloom.Size = 24
	bloom.Threshold = 1.4

	local color: ColorCorrectionEffect = effect("ColorCorrectionEffect", "CrownviaColor")
	color.Saturation = 0.12
	color.Contrast = 0.06
	color.Brightness = 0.02
	-- Gölgede kalan yüzler (çam modelleri) kapkara görünüyordu: ortam ışığını yükselt (2026-11-05).
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 158, 166)
	Lighting.Ambient = Color3.fromRGB(110, 118, 126)

	local dof: DepthOfFieldEffect = effect("DepthOfFieldEffect", "CrownviaDepth")
	dof.FarIntensity = 0.12
	dof.NearIntensity = 0.05
	dof.FocusDistance = 60
	dof.InFocusRadius = 40
	depth = dof
end

-- Her kare: netlik, kameranın baktığı yer düzlemindeki noktaya.
function Ambience.update()
	local dof = depth
	if dof == nil then
		return
	end
	local cframe = workspace.CurrentCamera.CFrame
	local look = cframe.LookVector
	if look.Y >= -1e-3 then
		return
	end
	local distance = -cframe.Position.Y / look.Y
	dof.FocusDistance = distance
	dof.InFocusRadius = distance * 0.55
end

return Ambience
