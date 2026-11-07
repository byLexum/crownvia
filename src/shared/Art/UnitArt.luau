--!strict
-- Yoldaki birlik modelleri: Roblox varlık kimlikleri (byLexum, 2026-11-02).
-- Üretim hattı: Magnific konsept + Meshy → tools/blender/prepare_unit.py (ön +X, boy 1,
-- sahip rengi alanları dokuda saydam). Anahtar `Unit.name`. Modeli olmayan birim küreyle çizilir.
-- Her birlik tek model (CLAUDE.md kural 5): birlikteki baskın birimin modeli.

export type Art = { mesh: number, texture: number, length: number, air: boolean }

local UnitArt = {}

UnitArt.meshes = {
	Soldier = { mesh = 72586709287311, texture = 78800197757415, length = 1.8, air = false },
	Tank = { mesh = 93539621650218, texture = 75627947142969, length = 2.2, air = false },
	Fighter = { mesh = 85513046121201, texture = 115516542970629, length = 2.6, air = true },
	Chopper = { mesh = 75045402725907, texture = 102288290874764, length = 2.6, air = true },
	Bomber = { mesh = 86971719437622, texture = 71580858620640, length = 3.2, air = true },
	Ruler = { mesh = 80329629134944, texture = 104368953191033, length = 2.6, air = false },
} :: { [string]: Art }

-- Uçuştaki boy (stud) ve hava birimi mi; kimlikler içe aktarılınca `meshes`e yazılır.
UnitArt.spec = {
	Soldier = { length = 1.8, air = false },
	Tank = { length = 2.2, air = false },
	Fighter = { length = 2.6, air = true },
	Chopper = { length = 2.6, air = true },
	Bomber = { length = 3.2, air = true },
	Ruler = { length = 2.6, air = false },
}

return UnitArt
