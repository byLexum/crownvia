--!strict
-- Kozmetik görselleri (Magnific ile üretildi, byLexum 2026-11-06; kaynak `dist/cosmetics/final/`).
-- Taçlar kendi renginde (ImageColor3 beyaz); halka ve mühür beyaz + saydamlık, sahip rengine boyanır.

local CosmeticArt = {}

CosmeticArt.images = {
	bronze_seal = "rbxassetid://140314138635473",
	steel_crown = "rbxassetid://90480979216293",
	gold_banner = "rbxassetid://85026104170086",
	veteran_crown = "rbxassetid://108953918323027",
	signal_crown = "rbxassetid://133679986479143",
	-- Beyaz dokular: fetihte sahip rengine boyanır (ok başı ve kıvılcım dokusu).
	chevron_strike = "rbxassetid://101512903999693",
	star_burst = "rbxassetid://97521382789307",
	iron_frame = "rbxassetid://104747886370917",
	command_frame = "rbxassetid://70860408906580",
	victory_ring = "rbxassetid://91205380993852",
	banner_seal = "rbxassetid://128161516470971",
	-- Çerçevenin defne simgesi halka dokusunu altına boyar.
	victor_frame = "rbxassetid://91205380993852",
	champion_frame = "rbxassetid://111129499460376",
} :: { [string]: string }

-- Mağaza önizlemeleri (tek aile: askeri damgalı metal, 2026-11-06; kaynak `dist/ui_f/out/`). Halka ve mühürün
-- oyundaki görseli beyaz ve sahip rengine boyanır; mağazada altın rozet gösterilir.
CosmeticArt.previews = {
	bronze_seal = "rbxassetid://140314138635473",
	steel_crown = "rbxassetid://90480979216293",
	gold_banner = "rbxassetid://85026104170086",
	veteran_crown = "rbxassetid://108953918323027",
	victory_ring = "rbxassetid://137976059214693",
	banner_seal = "rbxassetid://129707303227907",
	victor_frame = "rbxassetid://87409010058016",
	champion_frame = "rbxassetid://111129499460376",
	signal_crown = "rbxassetid://133679986479143",
	chevron_strike = "rbxassetid://73887967012708",
	star_burst = "rbxassetid://140159840656554",
	iron_frame = "rbxassetid://104747886370917",
	command_frame = "rbxassetid://70860408906580",
} :: { [string]: string }

CosmeticArt.creditPacks = {
	credits_small = "rbxassetid://122403521892127",
	credits_medium = "rbxassetid://134559064684191",
	credits_large = "rbxassetid://140133336252567",
	credits_starter = "rbxassetid://109009452732611",
} :: { [string]: string }

return CosmeticArt
