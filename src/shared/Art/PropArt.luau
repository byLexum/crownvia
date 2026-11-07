--!strict
-- Süs modelleri (ağaç, kaya): Roblox varlık kimlikleri (byLexum). Yalnız görsel, kural yok.
-- Üretim hattı: Magnific konsept + Meshy → tools/blender/prepare_unit.py (taban z=0, boy 1).
-- Kimlik 0 → içe aktarılmadı; istemci ilkel parçalarla çizer.

export type Art = { mesh: number, texture: number, height: number }

local PropArt = {}

-- 2026-11-05: Studio 3D Importer ile aktardı (`dist/props/import`). `height`: stud, kule
-- tabanı 6 stud; anahtar Territory'deki süs adı.
PropArt.meshes = {
	Pine = { mesh = 77750668374251, texture = 84274985327212, height = 3.6 },
	-- Doku 2026-11-05 açıldı (eski 95928505836747 çok koyuydu, oyunda kapkara görünüyordu).
	Pines = { mesh = 86026934350781, texture = 80929736136133, height = 3.9 },
	Rocks = { mesh = 136029832294105, texture = 78661611625367, height = 1.5 },
	-- 2026-11-05: Magnific (Nano Banana konsept → Tripo 3D) → tools/blender/prepare_unit.py.
	Pumpjack = { mesh = 96017901778878, texture = 120293197454199, height = 2.6 },
	Wreck = { mesh = 91371517196111, texture = 91154283988792, height = 1.3 },
	Crates = { mesh = 110943628979416, texture = 134819813123883, height = 1.1 },
	DeadTree = { mesh = 73177238923152, texture = 132767109178131, height = 2.8 },
	Fence = { mesh = 94256579883342, texture = 133266287159326, height = 0.9 },
} :: { [string]: Art }

return PropArt
