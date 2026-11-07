--!strict
-- Ana ekran: canlı dünya (hazır olana kadar anahtar görsel), logo, Play Solo, arkadaşlar, yardım,
-- genel sunucu listesi; altta mağaza, dolap, hedefler, sıralama çubuğu, sağ üstte Credits, sol altta
-- ayarlar (2026-11-06). Kiomet'te karşılığı oyun başındaki `SpawnOverlay` (client/src/ui/game_ui.rs):
-- oyuncu "Play"e basınca `Command::Spawn` gider. İlk doğuştan sonra bir daha gösterilmez; ölünce
-- DeathScreen devralır. Oyun kalıcı dünya: listedeki "Join" bulunulan dünyada doğurur ya da seçilen
-- genel sunucuya ışınlar (`PartyMenu.joinWorld`). Solo zorlukları `SoloMenu`.

local TweenService = game:GetService("TweenService")

local AccountView = require(script.Parent.AccountView)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local StartScreen = {}

type WorldRow = {
	id: string,
	name: string,
	players: number,
	max: number,
	leader: string?,
	here: boolean,
}

export type Actions = {
	play: () -> (),
	solo: () -> (),
	joinWorld: (id: string) -> (),
	friends: () -> (),
	help: () -> (),
	store: () -> (),
	locker: () -> (),
	goals: () -> (),
	rankings: () -> (),
	settings: () -> (),
}

-- Arka plan: Magnific anahtar görseli (F ailesi, 2026-11-06; kaynak `dist/v2/brand/keyart.png`).
local KEY_ART = "rbxassetid://122724824564603"

-- Canlı dünya görününce örtü bu kadar açılır (yazılar okunur kalır).
local LIVE_SHADE = 0.15
local LIVE_FADE_SECS = 1.2

local WORLD_ROW_HEIGHT = 64

local MAX_WORLD_ROWS = 2

local gui: ScreenGui? = nil
local worldList: ScrollingFrame? = nil
local worldRows: { WorldRow } = {}
local hereButton: Kit.Button? = nil
local joining = false
local joinHere: () -> () = function() end
local joinOther: (id: string) -> () = function(_id: string) end
local keyArt: ImageLabel? = nil
local keyShade: Frame? = nil

-- Alt çubuğun karosu: büyük ikon üstte, ad altta (parmakla rahat basılır, 140x96).
local DOCK_TILE = Vector2.new(140, 96)

local function dockTile(parent: Instance, order: number, icon: string, title: string, run: () -> ())
	local b = Kit.button(parent, {
		variant = "navy",
		size = UDim2.fromOffset(DOCK_TILE.X, DOCK_TILE.Y),
		order = order,
		name = title,
		onClick = run,
	})
	local face = b.root:FindFirstChild("Face") :: Frame
	local column = Kit.box(face, UDim2.fromScale(1, 1))
	Kit.list(column, {
		gap = 2,
		alignX = Enum.HorizontalAlignment.Center,
		alignY = Enum.VerticalAlignment.Center,
	})
	Kit.icon(column, icon, 52, 1)
	local text = Kit.text(column, title, "label", nil, UDim2.new(1, -8, 0, 24), 2)
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.TextWrapped = false
	text.TextSize = 19
end

-- Genel sunucu satırları (`WorldList.Row`, sunucudan gelir).
local function worldRow(parent: Instance, order: number, row: WorldRow)
	local box = Kit.well(parent, UDim2.new(1, 0, 0, WORLD_ROW_HEIGHT), order)
	box.Name = "World" .. order
	Kit.padding(box, 6, 10)
	Kit.list(box, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })
	Kit.icon(box, Icons.ui.map, 44, 1)
	local lines = Kit.box(box, UDim2.new(1, -174, 1, 0), 2)
	Kit.list(lines, { alignY = Enum.VerticalAlignment.Center })
	Kit.text(lines, row.name, "heading", nil, UDim2.new(1, 0, 0, 26), 1).TextSize = 19
	local detail = string.format(Strings.worldPlayers, row.players, row.max)
	if row.leader then
		detail ..= "  •  " .. string.format(Strings.worldLeader, row.leader)
	end
	local sub = Kit.text(lines, detail, "small", Theme.colors.muted, UDim2.new(1, 0, 0, 20), 2)
	sub.TextTruncate = Enum.TextTruncate.AtEnd
	local join = Kit.button(box, {
		variant = "navy",
		text = if row.here and joining then Strings.joining else Strings.worldJoin,
		textSize = 17,
		size = UDim2.fromOffset(104, 48),
		order = 3,
		name = "Join",
		onClick = function()
			if row.here then
				joinHere()
			else
				joinOther(row.id)
			end
		end,
	})
	if row.here then
		hereButton = join
	end
end

local function renderWorlds()
	local list = worldList
	if list == nil then
		return
	end
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	hereButton = nil
	for i, row in worldRows do
		worldRow(list, i, row)
	end
	-- Görünür yükseklik: satır sayısına göre, en fazla MAX_WORLD_ROWS (+ Kit.scroll dolgusu 6).
	local visible = math.clamp(#worldRows, 1, MAX_WORLD_ROWS)
	list.Size = UDim2.new(1, 0, 0, visible * WORLD_ROW_HEIGHT + (visible - 1) * 8 + 6)
	if #worldRows == 0 then
		local empty = Kit.text(list, Strings.worldsEmpty, "small", Theme.colors.muted, nil, 1)
		empty.TextXAlignment = Enum.TextXAlignment.Center
		empty.Size = UDim2.new(1, 0, 0, 24)
	end
end

function StartScreen.show(actions: Actions)
	if gui ~= nil then
		return
	end
	local screen = Kit.screen("StartScreen", 30, true)

	local background = Instance.new("ImageLabel")
	background.Name = "KeyArt"
	background.Size = UDim2.fromScale(1, 1)
	background.Image = KEY_ART
	background.ScaleType = Enum.ScaleType.Crop
	background.BackgroundColor3 = Theme.colors.background
	background.Parent = screen

	-- Lacivert örtü: anahtar görsel arayüzle aynı tonda, yazılar okunur.
	local shade = Instance.new("Frame")
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Theme.colors.background
	shade.BackgroundTransparency = 0.05
	shade.BorderSizePixel = 0
	shade.Parent = background
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.45, 0.25),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	gradient.Parent = shade

	local column = Kit.box(screen, UDim2.fromOffset(540, 0))
	column.Name = "Column"
	-- Üstten sabit: alttaki çubuğa taşmasın, sunucu listesi uzarsa aşağı büyür.
	column.AnchorPoint = Vector2.new(0.5, 0)
	column.Position = UDim2.new(0.5, 0, 0, 20)
	column.AutomaticSize = Enum.AutomaticSize.Y
	Kit.scaled(column)
	Kit.list(column, { gap = 8, alignX = Enum.HorizontalAlignment.Center })

	local logo = Kit.icon(column, Icons.logo, 0, 1)
	logo.Size = UDim2.fromOffset(400, math.floor(400 / Icons.LOGO_ASPECT))

	local tagline = Kit.text(column, Strings.tagline, "heading", Theme.colors.text, nil, 2)
	tagline.TextXAlignment = Enum.TextXAlignment.Center
	tagline.Size = UDim2.new(1, 0, 0, 28)

	local panel = Kit.panel(column, UDim2.fromOffset(540, 0), true, 18)
	panel.Name = "Panel"
	panel.LayoutOrder = 3
	panel.AutomaticSize = Enum.AutomaticSize.Y
	Kit.padding(panel, 14)
	Kit.list(panel, { gap = 10 })

	local head = Kit.box(panel, UDim2.new(1, 0, 0, 78), 1)
	Kit.list(head, { horizontal = true, gap = 10 })
	local solo = Kit.button(head, {
		variant = "gold",
		text = Strings.playSolo,
		textSize = 30,
		size = UDim2.fromOffset(340, 78),
		order = 1,
		name = "Solo",
		onClick = actions.solo,
	})
	Kit.iconButton(head, Icons.ui.friends, 70, actions.friends, 2, "Friends")
	Kit.iconButton(head, Icons.ui.help, 70, actions.help, 3, "Help")

	local title = Kit.text(panel, Strings.worldsTitle, "label", Theme.colors.gold, nil, 2)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Size = UDim2.new(1, 0, 0, 20)

	-- En çok MAX_WORLD_ROWS satır görünür, fazlası kaydırılır (alt çubuğa taşmasın).
	local worlds = Kit.scroll(panel, UDim2.new(1, 0, 0, WORLD_ROW_HEIGHT + 6), 8)
	worlds.Name = "Worlds"
	worlds.LayoutOrder = 3
	worldList = worlds

	joining = false
	joinHere = function()
		if joining then
			return
		end
		joining = true
		local button = hereButton
		if button then
			button.setText(Strings.joining)
		end
		actions.play()
	end
	joinOther = actions.joinWorld
	renderWorlds()

	-- Alt çubuk (2026-11-06): mağaza, dolap, hedefler, sıralama. Ekranın altında ortada, cam panel.
	local dock = Kit.panel(screen, UDim2.fromOffset(0, 0), true, 22)
	dock.Name = "Dock"
	dock.AnchorPoint = Vector2.new(0.5, 1)
	dock.Position = UDim2.new(0.5, 0, 1, -14)
	dock.AutomaticSize = Enum.AutomaticSize.XY
	Kit.padding(dock, 10)
	Kit.list(dock, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })
	Kit.scaled(dock)
	dockTile(dock, 1, Icons.ui.store, Strings.storeTitle, actions.store)
	dockTile(dock, 2, Icons.ui.locker, Strings.lockerTitle, actions.locker)
	dockTile(dock, 3, Icons.ui.goal, Strings.dailyGoals, actions.goals)
	dockTile(dock, 4, Icons.ui.trophy, Strings.rankingsTitle, actions.rankings)

	-- Credits sağ üstte (Roblox menüsü sol üstte).
	local coins, credits = Kit.pill(screen, Icons.ui.coin, "0", Theme.colors.gold, 52, 0)
	coins.Name = "Credits"
	coins.AnchorPoint = Vector2.new(1, 0)
	coins.Position = UDim2.new(1, -16, 0, 14)
	Kit.scaled(coins)
	local function refresh()
		local profile = AccountView.profile()
		credits.Text = if profile then tostring(profile.credits) else "..."
	end
	AccountView.onProfileChanged(refresh)
	refresh()

	-- Ayarlar sol altta.
	local settings = Kit.iconButton(screen, Icons.ui.gear, 68, actions.settings, 0, "Settings")
	settings.root.AnchorPoint = Vector2.new(0, 1)
	settings.root.Position = UDim2.new(0, 16, 1, -16)
	Kit.scaled(settings.root)

	Kit.mount(screen)
	gui = screen
	keyArt = background
	keyShade = shade
	-- Hafif nabız: ana düğme dikkat çeksin.
	local pulse = Instance.new("UIScale")
	pulse.Parent = solo.root
	TweenService:Create(
		pulse,
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.03 }
	):Play()
end

-- İlk `Hello`: ekran kaybolur.
function StartScreen.hide()
	local screen = gui
	if screen == nil then
		return
	end
	gui = nil
	worldList = nil
	hereButton = nil
	keyArt = nil
	keyShade = nil
	screen:Destroy()
end

-- Play Solo ile gelindi: ikinci kez Play'e basılmaz.
function StartScreen.autoPlay()
	joinHere()
end

-- Sunucu `Worlds`: liste değişti.
function StartScreen.setWorlds(rows: { WorldRow })
	worldRows = rows
	renderWorlds()
end

-- Canlı dünya çizildi: anahtar görsel söner, örtü açılır. Bot yoksa çağrılmaz, görsel kalır.
function StartScreen.showLiveWorld()
	local art, shade = keyArt, keyShade
	if art == nil or shade == nil then
		return
	end
	keyArt = nil
	local info = TweenInfo.new(LIVE_FADE_SECS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	TweenService:Create(art, info, { ImageTransparency = 1, BackgroundTransparency = 1 }):Play()
	TweenService:Create(shade, info, { BackgroundTransparency = LIVE_SHADE }):Play()
end

-- Doğuş başarısız: düğme yeniden denenebilir. DeathScreen hatayı gösterir; burada yalnız açılır.
function StartScreen.isVisible(): boolean
	return gui ~= nil
end

return StartScreen
