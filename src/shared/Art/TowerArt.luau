--!strict
-- Kule 3D modelleri: Roblox varlık kimlikleri (byLexum, Studio 3D içe aktarıcı, 2026-11-02).
-- Üretim hattı: tools/art (konsept + Meshy) → tools/blender/prepare_ai_tower.py.
-- Dokuda sahip rengi alanları (bayrak, şerit, taban kenarı) saydamdır; MeshPart.Color oradan görünür.
-- Anahtar `TowerTypeId.name`. Eksik tip kutu olarak çizilir.

export type Art = { mesh: number, texture: number }

local TowerArt: { [string]: Art } = {
	Airfield = { mesh = 88608071428026, texture = 133383521984370 },
	Armory = { mesh = 76032214715255, texture = 113293579036072 },
	Artillery = { mesh = 72553764930044, texture = 79257804622777 },
	Barracks = { mesh = 71123514541508, texture = 79464986876160 },
	Bunker = { mesh = 74412096698366, texture = 76267298751187 },
	Centrifuge = { mesh = 98363789731204, texture = 78068456300262 },
	City = { mesh = 113151666681475, texture = 122770755225444 },
	Cliff = { mesh = 98811067547941, texture = 82143225385345 },
	Ews = { mesh = 102345943363580, texture = 138076421288852 },
	Factory = { mesh = 138178487839302, texture = 106085277806025 },
	Generator = { mesh = 109190936634466, texture = 126561141149655 },
	Headquarters = { mesh = 123776355635567, texture = 135370759628404 },
	Helipad = { mesh = 98238469093571, texture = 93682555645940 },
	Launcher = { mesh = 108435727682124, texture = 128891669413040 },
	Mine = { mesh = 124924095211290, texture = 85830872259801 },
	Projector = { mesh = 140077795698357, texture = 136303415608717 },
	Quarry = { mesh = 125543898294502, texture = 112177227068685 },
	Radar = { mesh = 105576916104185, texture = 130537468624949 },
	Rampart = { mesh = 109019881492605, texture = 110103286889386 },
	Reactor = { mesh = 128730347462790, texture = 111418791330488 },
	Refinery = { mesh = 97253607041146, texture = 102342009365480 },
	Rocket = { mesh = 78146255900948, texture = 105353130783803 },
	Runway = { mesh = 123366128531188, texture = 131991854118804 },
	Satellite = { mesh = 128335449999944, texture = 132980087765788 },
	Silo = { mesh = 139864507959417, texture = 97744539326958 },
	Town = { mesh = 83616460852222, texture = 111230985580041 },
	Village = { mesh = 97750445088152, texture = 126961660476180 },
}

return TowerArt
