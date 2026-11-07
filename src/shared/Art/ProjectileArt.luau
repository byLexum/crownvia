--!strict
-- Menzilli mermi modelleri ve efekt dokuları: Roblox varlık kimlikleri (byLexum; F ailesi 2026-11-06,
-- kaynak `dist/v2/import`).
-- Üretim hattı: Magnific konsept + Meshy → tools/blender/prepare_projectile.py (burun +X, boy 1).
-- Anahtar `Unit.name`. Modeli olmayan mermi ilkel parçalarla çizilir.

export type Art = { mesh: number, texture: number, length: number }

local ProjectileArt = {}

-- Uçuştaki boy (stud).
ProjectileArt.meshes = {
	Shell = { mesh = 110512618072158, texture = 138604042704941, length = 1.6 },
	Emp = { mesh = 88412647121633, texture = 114844575691488, length = 2.2 },
	Nuke = { mesh = 94853332271758, texture = 135061763275718, length = 3.4 },
} :: { [string]: Art }

-- Parçacık dokuları (F ailesi, 2026-11-06; kaynak `dist/ui_f/out/fx_*.png`). Halka, duman ve
-- kıvılcım beyaz: `Color` ile sahip rengine boyanır. Eski halka mavi olduğu için boyandığında renk
-- bozuluyordu.
ProjectileArt.fx = {
	fire = "rbxassetid://116119650658994",
	smoke = "rbxassetid://120132040564621",
	ring = "rbxassetid://103730931492209",
	spark = "rbxassetid://97521382789307",
}

return ProjectileArt
