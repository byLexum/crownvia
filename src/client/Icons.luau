--!strict
-- Arayüz ikonları (F ailesi, Magnific; kaynak `dist/ui_f/out/`, `tools/art/cut_ui_sheet.py` ile
-- kesildi, MCP upload_image ile yüklendi, byLexum 2026-11-06).
-- Birim ikonları `Unit` kimliğine göre (Unit.luau sırası).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Unit =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"):WaitForChild("Unit"))

local Icons = {}

Icons.crown = "rbxassetid://115776332276539"
-- Öğretici sürükleme imleci.
Icons.hand = "rbxassetid://71297349320217"
Icons.logo = "rbxassetid://121024616572345"
Icons.LOGO_ASPECT = 1024 / 358
-- Yükleme ekranı arka planı (Magnific anahtar görseli, kaynak `dist/store/promo/public/img/keyart.jpg`,
-- 1024 px'e küçültüldü `dist/loading/loading_bg.jpg`; byLexum 2026-11-07).
Icons.loadingArt = "rbxassetid://78052356744975"
Icons.LOADING_ART_ASPECT = 1024 / 571

Icons.ui = {
	coin = "rbxassetid://114875008442973",
	tower = "rbxassetid://97347256947354",
	trophy = "rbxassetid://88463381183032",
	gear = "rbxassetid://120512915337566",
	friends = "rbxassetid://112481402911046",
	store = "rbxassetid://96990170549977",
	locker = "rbxassetid://94921491732190",
	help = "rbxassetid://115471248226819",
	goal = "rbxassetid://89471448818296",
	lock = "rbxassetid://93584323407973",
	check = "rbxassetid://132770637621814",
	warning = "rbxassetid://101718329732698",
	flag = "rbxassetid://125916938223295",
	map = "rbxassetid://86147893126617",
	invite = "rbxassetid://130428021163767",
	radar = "rbxassetid://139636027988707",
	truck = "rbxassetid://80499662953947",
	rankOne = "rbxassetid://129902184944805",
	rankTwo = "rbxassetid://75694554771340",
	rankThree = "rbxassetid://89327633810002",
} :: { [string]: string }

Icons.units = {
	[Unit.Shield] = "rbxassetid://115294212617956",
	[Unit.Fighter] = "rbxassetid://76567125602567",
	[Unit.Chopper] = "rbxassetid://108455980484819",
	[Unit.Bomber] = "rbxassetid://139725424516578",
	[Unit.Tank] = "rbxassetid://74706602769505",
	[Unit.Soldier] = "rbxassetid://117286500288949",
	[Unit.Shell] = "rbxassetid://92769689051748",
	[Unit.Emp] = "rbxassetid://119860010850670",
	[Unit.Nuke] = "rbxassetid://79114866749194",
	[Unit.Ruler] = "rbxassetid://111891754951808",
} :: { [number]: string }

-- Ön yükleme: ikonlar ilk kullanımda geç beliriyordu (kral uyarısının üçgeni dahil).
function Icons.all(): { string }
	local list = { Icons.crown, Icons.logo, Icons.hand }
	for _, image in Icons.ui do
		table.insert(list, image)
	end
	for _, image in Icons.units do
		table.insert(list, image)
	end
	return list
end

return Icons
