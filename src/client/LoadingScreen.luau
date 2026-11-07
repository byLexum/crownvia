--!strict
-- Açılış yükleme ekranı: görseller, modeller ve sesler inmeden oyun görünmez. Oyuncunun oyunda
-- gördüğü ilk ekran olduğu için dolu ve canlı: anahtar görsel arka planda yavaşça kayar, üstünden
-- hava birimleri geçer, logo sekerek gelir, ipuçları ikonlarıyla döner, çubuk parlar.
-- Logo ve arka plan hemen gelir, kalan parça parça yüklenir; çubuk gerçek sayıyı yumuşakça izler.
-- Ağ bozuksa MAX_WAIT sonunda oyun yine açılır, oyuncu ekranda takılmaz.
-- Aynı görünümün durağan bir kopyası ışınlama ekranıdır (`setupTeleport`): Roblox ışınlama
-- sırasında bu arayüzün içinde betik çalıştırmaz, o yüzden hareketsiz.
-- proje kararı (2026-11-06): ana yükleme girişte, mod seçerken ağır yükleme yok.
-- geliştirici isteği (2026-11-07): ilk izlenim ekranı, daha estetik ve dolu.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)
local Unit =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"):WaitForChild("Unit"))

local LoadingScreen = {}

local CHUNK = 12
local MAX_WAIT = 30
local FADE_SECS = 0.5
local TIP_SECS = 4.5
local TIP_FADE = 0.25
local BAR_SMOOTH = 7
-- Arka plan yavaşça yakınlaşıp kayar (Ken Burns); taşma payı ekran kenarı görünmesin diye.
local ART_OVERSCAN = 1.12
local ART_ZOOM = 0.05
local ART_PAN = 0.02
local ART_CYCLE_SECS = 30
local ART_FADE_SECS = 0.9
-- Logo girişi: küçükten hafif sekmeyle büyür, sonra yavaşça süzülür.
local LOGO_POP_SECS = 0.7
-- Çubuğun üstünde kayan parlama.
local SHINE_SECS = 1.8
-- Haritanın üstünden geçen hava birimleri: (birim, yükseklik, hız ekran/sn, boyut, yön).
local FLYERS = {
	{ Unit.Fighter, 0.13, 0.075, 56, 1 },
	{ Unit.Bomber, 0.27, 0.045, 70, -1 },
	{ Unit.Chopper, 0.58, 0.055, 52, 1 },
	{ Unit.Fighter, 0.66, 0.090, 44, -1 },
}
-- Her ipucunun yanındaki ikon (Strings.loadingTips sırasıyla).
local TIP_ICONS: { string } = {
	Icons.hand,
	Icons.units[Unit.Ruler],
	Icons.crown,
	Icons.ui.tower,
	Icons.ui.truck,
	Icons.ui.radar,
	Icons.ui.tower,
	Icons.units[Unit.Emp],
	Icons.units[Unit.Nuke],
	Icons.ui.friends,
}

type Flyer = { image: ImageLabel, x: number, y: number, speed: number, dir: number, phase: number }
type Built = {
	screen: ScreenGui,
	back: GuiObject,
	art: ImageLabel,
	logo: ImageLabel,
	logoScale: UIScale,
	status: TextLabel,
	percent: TextLabel?,
	fill: Frame?,
	shine: UIGradient?,
	tip: TextLabel,
	tipIcon: ImageLabel,
	flyers: { Flyer },
}

local current: Built? = nil
local connection: RBXScriptConnection? = nil
local arriving: Instance? = nil
local target = 0
local shown = 0

-- Saydamlığı bir yönde değişen koyu katman (`from`/`to`: 0 = opak, 1 = görünmez).
local function shade(
	parent: Instance,
	rotation: number,
	from: number,
	to: number,
	name: string
): Frame
	local f = Kit.box(parent, UDim2.fromScale(1, 1))
	f.Name = name
	f.BackgroundTransparency = 0
	f.BackgroundColor3 = Theme.colors.background
	local g = Instance.new("UIGradient")
	g.Rotation = rotation
	g.Transparency = NumberSequence.new(from, to)
	g.Parent = f
	return f
end

local function setTip(built: Built, index: number)
	built.tip.Text = Strings.loadingTips[index]
	built.tipIcon.Image = TIP_ICONS[index] or Icons.ui.tower
end

local function chip(parent: Instance, text: string, order: number)
	local f = Instance.new("Frame")
	f.Name = "Chip"
	f.LayoutOrder = order
	f.Size = UDim2.fromOffset(0, 30)
	f.AutomaticSize = Enum.AutomaticSize.X
	f.BackgroundColor3 = Theme.colors.panel
	f.BackgroundTransparency = 0.15
	f.BorderSizePixel = 0
	Kit.corner(f, 15)
	Kit.stroke(f, Theme.colors.stroke, 1.5)
	Kit.padding(f, 0, 16, 0, 16)
	f.Parent = parent
	local label = Kit.text(f, text, "small", Theme.colors.text, UDim2.fromOffset(0, 30))
	label.AutomaticSize = Enum.AutomaticSize.X
	label.TextWrapped = false
	label.FontFace = Theme.fonts.strong
	label.TextSize = 15
end

-- Ekranı kurar. `animated`: false ise (ışınlama) çubuk, uçan birim ve hareket yok.
local function build(animated: boolean): Built
	local screen = Kit.screen(if animated then "LoadingScreen" else "TeleportLoading", 100, true)
	-- Hareketli sürümde tek parça solma için CanvasGroup; ışınlama sürümü düz Frame.
	local back: GuiObject = if animated then Instance.new("CanvasGroup") else Instance.new("Frame")
	back.Name = "Back"
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Theme.colors.background
	back.BackgroundTransparency = 0
	back.BorderSizePixel = 0
	back.ClipsDescendants = true
	back.Parent = screen
	-- Görsel inene kadar görünen zemin.
	local ground = Kit.box(back, UDim2.fromScale(1, 1))
	ground.Name = "Ground"
	ground.BackgroundTransparency = 0
	ground.BackgroundColor3 = Color3.new(1, 1, 1)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Color3.fromRGB(24, 38, 74), Color3.fromRGB(8, 13, 26))
	gradient.Rotation = 90
	gradient.Parent = ground

	-- Anahtar görsel: ekranı her en-boy oranında doldurur (kenarlar kırpılır).
	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundTransparency = 1
	art.Image = Icons.loadingArt
	art.ScaleType = Enum.ScaleType.Crop
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.5)
	art.Size = UDim2.fromScale(ART_OVERSCAN, ART_OVERSCAN)
	art.ImageTransparency = if animated then 1 else 0
	art.Parent = back

	-- Okunurluk: hafif lacivert tül, üst ve alt kararır, yanlar vinyet.
	local tint = Kit.box(back, UDim2.fromScale(1, 1))
	tint.Name = "Tint"
	tint.BackgroundTransparency = 0.62
	tint.BackgroundColor3 = Theme.colors.background
	shade(back, 90, 0.1, 1, "TopShade").Size = UDim2.fromScale(1, 0.5)
	local bottom = shade(back, 90, 1, 0, "BottomShade")
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)
	bottom.Size = UDim2.fromScale(1, 0.5)
	shade(back, 0, 0.2, 1, "LeftShade").Size = UDim2.fromScale(0.28, 1)
	local right = shade(back, 180, 0.2, 1, "RightShade")
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.fromScale(1, 0)
	right.Size = UDim2.fromScale(0.28, 1)

	local flyers: { Flyer } = {}
	if animated then
		for i, spec in FLYERS do
			local image = Instance.new("ImageLabel")
			image.Name = "Flyer"
			image.BackgroundTransparency = 1
			image.Image = Icons.units[spec[1]] or ""
			image.ImageTransparency = 0.3
			image.ScaleType = Enum.ScaleType.Fit
			image.AnchorPoint = Vector2.new(0.5, 0.5)
			image.Size = UDim2.fromOffset(spec[4], spec[4])
			image.Parent = back
			Kit.scaled(image)
			table.insert(flyers, {
				image = image,
				x = (i * 0.31) % 1,
				y = spec[2],
				speed = spec[3],
				dir = spec[5],
				phase = i * 1.3,
			})
		end
	end

	-- Orta sütun: logo, slogan, üç vaat.
	local column = Kit.box(back, UDim2.fromOffset(640, 0))
	column.Name = "Column"
	column.AnchorPoint = Vector2.new(0.5, 0.5)
	column.Position = UDim2.fromScale(0.5, 0.37)
	column.AutomaticSize = Enum.AutomaticSize.Y
	Kit.scaled(column)
	Kit.list(column, { gap = 10, alignX = Enum.HorizontalAlignment.Center })

	local logoWidth = 500
	local logoHeight = math.floor(logoWidth / Icons.LOGO_ASPECT)
	local holder = Kit.box(column, UDim2.fromOffset(logoWidth, logoHeight + 14), 1)
	local logo = Kit.icon(holder, Icons.logo, 0, 1)
	logo.AnchorPoint = Vector2.new(0.5, 0.5)
	logo.Position = UDim2.fromScale(0.5, 0.5)
	logo.Size = UDim2.fromOffset(logoWidth, logoHeight)
	local logoScale = Instance.new("UIScale")
	logoScale.Scale = if animated then 0.8 else 1
	logoScale.Parent = logo
	if animated then
		logo.ImageTransparency = 1
	end

	local tagline = Kit.text(column, Strings.tagline, "title", Theme.colors.gold, nil, 2)
	tagline.TextXAlignment = Enum.TextXAlignment.Center
	tagline.Size = UDim2.new(1, 0, 0, 34)
	local tagStroke = Instance.new("UIStroke")
	tagStroke.Color = Theme.colors.background
	tagStroke.Thickness = 3
	tagStroke.Transparency = 0
	tagStroke.Parent = tagline

	local pitch = Kit.box(column, UDim2.new(1, 0, 0, 30), 3)
	pitch.Name = "Pitch"
	Kit.list(pitch, {
		horizontal = true,
		gap = 10,
		alignX = Enum.HorizontalAlignment.Center,
	})
	for i, word in Strings.loadingPitch do
		chip(pitch, word, i)
	end

	-- Alt blok: ipucu kartı, çubuk, durum.
	local foot = Kit.box(back, UDim2.fromOffset(560, 0))
	foot.Name = "Foot"
	foot.AnchorPoint = Vector2.new(0.5, 1)
	foot.Position = UDim2.new(0.5, 0, 0.96, 0)
	foot.AutomaticSize = Enum.AutomaticSize.Y
	Kit.scaled(foot)
	Kit.list(foot, { gap = 10, alignX = Enum.HorizontalAlignment.Center })

	local card = Instance.new("Frame")
	card.Name = "TipCard"
	card.LayoutOrder = 1
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = Theme.colors.panel
	card.BackgroundTransparency = 0.1
	card.BorderSizePixel = 0
	Kit.corner(card, 18)
	Kit.stroke(card, Theme.colors.stroke, 1.5)
	Kit.padding(card, 12, 18, 12, 12)
	Kit.list(card, {
		horizontal = true,
		gap = 14,
		alignY = Enum.VerticalAlignment.Center,
	})
	card.Parent = foot

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.LayoutOrder = 1
	badge.Size = UDim2.fromOffset(58, 58)
	badge.BackgroundColor3 = Theme.colors.well
	badge.BorderSizePixel = 0
	Kit.corner(badge, 14)
	Kit.stroke(badge, Theme.colors.gold, 2)
	badge.Parent = card
	local tipIcon = Kit.icon(badge, Icons.ui.tower, 44)
	tipIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	tipIcon.Position = UDim2.fromScale(0.5, 0.5)

	local words = Kit.box(card, UDim2.new(1, -72, 0, 0), 2)
	words.Name = "Words"
	words.AutomaticSize = Enum.AutomaticSize.Y
	Kit.list(words, { gap = 2 })
	local tipLabel = Kit.text(words, Strings.tipLabel, "small", Theme.colors.gold, nil, 1)
	tipLabel.FontFace = Theme.fonts.strong
	tipLabel.TextSize = 15
	local tip = Kit.paragraph(words, "", "body", Theme.colors.text)
	tip.LayoutOrder = 2

	local fill: Frame? = nil
	local shine: UIGradient? = nil
	local percent: TextLabel? = nil
	local status: TextLabel
	if animated then
		local track = Instance.new("Frame")
		track.Name = "Bar"
		track.LayoutOrder = 2
		track.Size = UDim2.new(1, 0, 0, 16)
		track.BackgroundColor3 = Theme.colors.well
		track.BorderSizePixel = 0
		Kit.corner(track, 8)
		Kit.stroke(track, Theme.colors.stroke, 1.5)
		track.Parent = foot
		local barFill = Instance.new("Frame")
		barFill.Name = "Fill"
		barFill.Size = UDim2.fromScale(0, 1)
		barFill.BackgroundColor3 = Color3.new(1, 1, 1)
		barFill.BorderSizePixel = 0
		Kit.corner(barFill, 8)
		barFill.Parent = track
		local light = Color3.fromRGB(255, 238, 178)
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.colors.gold),
			ColorSequenceKeypoint.new(0.4, Theme.colors.gold),
			ColorSequenceKeypoint.new(0.5, light),
			ColorSequenceKeypoint.new(0.6, Theme.colors.gold),
			ColorSequenceKeypoint.new(1, Theme.colors.gold),
		})
		g.Offset = Vector2.new(-1, 0)
		g.Parent = barFill
		fill, shine = barFill, g

		local row = Kit.box(foot, UDim2.new(1, 0, 0, 24), 3)
		row.Name = "StatusRow"
		status = Kit.text(row, Strings.loading, "label", Theme.colors.muted, UDim2.fromScale(1, 1))
		local p = Kit.text(row, "0%", "label", Theme.colors.gold, UDim2.fromScale(1, 1))
		p.TextXAlignment = Enum.TextXAlignment.Right
		percent = p
	else
		status = Kit.text(foot, Strings.teleporting, "label", Theme.colors.muted, nil, 3)
		status.TextXAlignment = Enum.TextXAlignment.Center
	end

	local built: Built = {
		screen = screen,
		back = back,
		art = art,
		logo = logo,
		logoScale = logoScale,
		status = status,
		percent = percent,
		fill = fill,
		shine = shine,
		tip = tip,
		tipIcon = tipIcon,
		flyers = flyers,
	}
	setTip(built, math.random(1, #Strings.loadingTips))
	return built
end

local function nextTip(built: Built)
	local tips = Strings.loadingTips
	local index = table.find(tips, built.tip.Text) or 0
	local info = TweenInfo.new(TIP_FADE)
	TweenService:Create(built.tip, info, { TextTransparency = 1 }):Play()
	TweenService:Create(built.tipIcon, info, { ImageTransparency = 1 }):Play()
	task.delay(TIP_FADE, function()
		if current ~= built then
			return
		end
		setTip(built, index % #tips + 1)
		TweenService:Create(built.tip, info, { TextTransparency = 0 }):Play()
		TweenService:Create(built.tipIcon, info, { ImageTransparency = 0 }):Play()
	end)
end

-- Giriş: logo seker, görsel inince yumuşakça açılır (inene kadar gradyan zemin görünür).
local function intro(built: Built)
	TweenService:Create(
		built.logoScale,
		TweenInfo.new(LOGO_POP_SECS, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()
	TweenService:Create(built.logo, TweenInfo.new(LOGO_POP_SECS * 0.6), { ImageTransparency = 0 })
		:Play()
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ built.art })
		end)
		if current == built then
			TweenService:Create(built.art, TweenInfo.new(ART_FADE_SECS), { ImageTransparency = 0 })
				:Play()
		end
	end)
end

function LoadingScreen.show()
	if current ~= nil then
		return
	end
	-- Işınlamayla gelindiyse Roblox'un getirdiği ekranı (aynı görünüm) üstte tut, bizimki yüklenirken
	-- altından devralsın; hide'da ikisi birlikte kalkar.
	local ok, gui = pcall(function()
		return TeleportService:GetArrivingTeleportGui()
	end)
	if ok and gui ~= nil then
		local guiObject = gui :: Instance
		if guiObject:IsA("ScreenGui") then
			guiObject.DisplayOrder = 101
		end
		guiObject.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")
		arriving = guiObject
	end
	local built = build(true)
	Kit.mount(built.screen)
	current = built
	target, shown = 0, 0
	intro(built)
	local elapsed, tipTimer = 0, 0
	connection = RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		-- Arka plan: yavaş yakınlaşma ve yatay kayma, döngü sonsuz ve dikişsiz (sinüs).
		local wave = math.sin(elapsed * 2 * math.pi / ART_CYCLE_SECS)
		local zoom = ART_OVERSCAN + ART_ZOOM * (0.5 + 0.5 * wave)
		built.art.Size = UDim2.fromScale(zoom, zoom)
		built.art.Position = UDim2.fromScale(0.5 + ART_PAN * wave, 0.5)
		if elapsed > LOGO_POP_SECS then
			built.logo.Position = UDim2.new(0.5, 0, 0.5, math.sin(elapsed * 1.6) * 5)
		end
		for _, f in built.flyers do
			f.x += f.speed * f.dir * dt
			if f.x > 1.12 then
				f.x = -0.12
			elseif f.x < -0.12 then
				f.x = 1.12
			end
			local bob = math.sin(elapsed * 1.4 + f.phase) * 0.012
			f.image.Position = UDim2.fromScale(f.x, f.y + bob)
			-- İkonlar sağa bakıyor; sola uçan aynalanır (ters çevrilmiş görünmesin diye 180 + eğim).
			local tilt = math.cos(elapsed * 1.4 + f.phase) * 6
			f.image.Rotation = if f.dir < 0 then 180 - tilt else tilt
		end
		shown += (target - shown) * math.min(1, dt * BAR_SMOOTH)
		if built.fill then
			built.fill.Size = UDim2.fromScale(math.clamp(shown, 0, 1), 1)
		end
		if built.shine then
			local t = (elapsed % SHINE_SECS) / SHINE_SECS
			built.shine.Offset = Vector2.new(-1 + 2 * t, 0)
		end
		if built.percent then
			built.percent.Text = string.format("%d%%", math.floor(math.clamp(shown, 0, 1) * 100))
		end
		tipTimer += dt
		if tipTimer >= TIP_SECS then
			tipTimer = 0
			nextTip(built)
		end
	end)
end

-- Çubuğu etkilemeyen hızlı ön yükleme (logo gibi): ilerleme yüzdesi yalnız `load`dan gelir,
-- aksi halde çubuk önce %100'e çıkıp sonra geri düşüyordu.
function LoadingScreen.preload(items: { any })
	pcall(function()
		ContentProvider:PreloadAsync(items)
	end)
end

-- `items`: ContentProvider'a verilecek kimlikler ve nesneler. Bitince döner.
function LoadingScreen.load(items: { any })
	local total = math.max(#items, 1)
	local done = 0
	local deadline = os.clock() + MAX_WAIT
	while done < #items and os.clock() < deadline do
		local chunk = {}
		for i = done + 1, math.min(done + CHUNK, #items) do
			table.insert(chunk, items[i])
		end
		pcall(function()
			ContentProvider:PreloadAsync(chunk)
		end)
		done += #chunk
		target = done / total
	end
	target = 1
	-- Çubuk dolmayı bitirsin (ani kesilip kaybolmasın), ama oyuncuyu uzun bekletme.
	local waited = 0
	while shown < 0.985 and waited < 0.6 do
		waited += task.wait()
	end
end

-- Ana yükleme ekranı hâlâ ekranda mı (pencereler onu beklesin).
function LoadingScreen.isShowing(): boolean
	return current ~= nil
end

function LoadingScreen.hide()
	local built = current
	if built == nil then
		return
	end
	current = nil
	if connection then
		connection:Disconnect()
		connection = nil
	end
	local old = arriving
	arriving = nil
	local back = built.back :: CanvasGroup
	TweenService:Create(back, TweenInfo.new(FADE_SECS), { GroupTransparency = 1 }):Play()
	task.delay(FADE_SECS, function()
		built.screen:Destroy()
		if old then
			old:Destroy()
		end
	end)
end

-- Işınlama ekranı: aynı görünüm, durağan. Roblox ışınlamada bunu gösterir ve hedef yerde
-- `GetArrivingTeleportGui` ile verir (`show` devralır). Studio'da ışınlama çalışmaz: yayında denenir.
function LoadingScreen.setupTeleport()
	local gui = build(false).screen
	gui.Parent = ReplicatedStorage
	local ok = pcall(function()
		TeleportService:SetTeleportGui(gui)
	end)
	if not ok then
		gui:Destroy()
	end
end

return LoadingScreen
