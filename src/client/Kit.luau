--!strict
-- CROWNVIA arayüz kiti (F: Rounded Arcade Navy, proje kararı 2026-11-06). Tüm ekranlar bu parçaları
-- kullanır; görsel dil tek yerde durur. Renk anlamları sabit (Theme.colors):
--   altın = ana eylem ve Credits, yeşil = Robux satın alma, kırmızı = acil savaş uyarısı.
--   Takım aidiyeti (mavi/mor/kırmızı) yalnız haritada ve oyuncu adlarında.
-- Boyutlar 1040x620 tasarım pikselinde verilir; kapsayıcı `Kit.scaled` ile UIScale alır, köşelere
-- ölçek tabanlı konumlanır. Telefon (844x390) ~0,63: tasarımda 72 px düğme ekranda ~45 px.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Audio = require(script.Parent.Audio)
local Theme = require(script.Parent.Theme)

local Kit = {}

local DESIGN_WIDTH = 1040
local DESIGN_HEIGHT = 620
local MIN_SCALE = 0.56
local MAX_SCALE = 1.35

-- Roblox metin yazı tipinde Robux simgesi (U+E002).
Kit.ROBUX = utf8.char(0xE002)

local scales: { UIScale } = {}

local function currentScale(): number
	local camera = workspace.CurrentCamera
	local size = if camera then camera.ViewportSize else Vector2.new(DESIGN_WIDTH, DESIGN_HEIGHT)
	local s = math.min(size.Y / DESIGN_HEIGHT, size.X / DESIGN_WIDTH)
	return math.clamp(s, MIN_SCALE, MAX_SCALE)
end

function Kit.scale(): number
	return currentScale()
end

local function refreshScales()
	local value = currentScale()
	for _, s in scales do
		s.Scale = value
	end
end

local function watchCamera(camera: Camera?)
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshScales)
	end
end
watchCamera(workspace.CurrentCamera)
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	watchCamera(workspace.CurrentCamera)
	refreshScales()
end)

-- Süre metni: 93784 sn → "1d 2h", 4500 → "1h 15m", 600 → "10m" (en az 1m).
function Kit.duration(seconds: number): string
	seconds = math.max(math.floor(seconds), 0)
	local days = seconds // 86400
	local hours = seconds % 86400 // 3600
	local minutes = seconds % 3600 // 60
	if days > 0 then
		return string.format("%dd %dh", days, hours)
	elseif hours > 0 then
		return string.format("%dh %dm", hours, minutes)
	end
	return string.format("%dm", math.max(minutes, 1))
end

-- Öğeye ekran boyutunu izleyen UIScale ekler.
function Kit.scaled(target: GuiObject)
	local s = Instance.new("UIScale")
	s.Scale = currentScale()
	s.Parent = target
	table.insert(scales, s)
end

function Kit.screen(name: string, order: number, fullBleed: boolean?): ScreenGui
	local g = Instance.new("ScreenGui")
	g.Name = name
	g.ResetOnSpawn = false
	g.DisplayOrder = order
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	if fullBleed then
		g.IgnoreGuiInset = true
	else
		g.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	end
	return g
end

function Kit.mount(g: ScreenGui)
	g.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")
end

function Kit.corner(parent: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

function Kit.stroke(parent: GuiObject, color: Color3?, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.colors.stroke
	s.Thickness = thickness or 1.5
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

function Kit.padding(parent: Instance, top: number, right: number?, bottom: number?, left: number?)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, top)
	p.PaddingRight = UDim.new(0, right or top)
	p.PaddingBottom = UDim.new(0, bottom or top)
	p.PaddingLeft = UDim.new(0, left or right or top)
	p.Parent = parent
end

export type ListOptions = {
	horizontal: boolean?,
	gap: number?,
	alignX: Enum.HorizontalAlignment?,
	alignY: Enum.VerticalAlignment?,
}

function Kit.list(parent: Instance, options: ListOptions?): UIListLayout
	local o: ListOptions = options or {}
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.FillDirection = if o.horizontal
		then Enum.FillDirection.Horizontal
		else Enum.FillDirection.Vertical
	l.Padding = UDim.new(0, o.gap or 0)
	l.HorizontalAlignment = o.alignX or Enum.HorizontalAlignment.Left
	l.VerticalAlignment = o.alignY or Enum.VerticalAlignment.Top
	l.Parent = parent
	return l
end

-- Boş kapsayıcı.
function Kit.box(parent: Instance?, size: UDim2, order: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Size = size
	f.LayoutOrder = order or 0
	f.Parent = parent
	return f
end

export type TextStyle = "display" | "title" | "heading" | "label" | "body" | "small"

local TEXT_STYLES: { [TextStyle]: { size: number, font: Font } } = {
	display = { size = 40, font = Theme.fonts.heading },
	title = { size = 28, font = Theme.fonts.heading },
	heading = { size = 23, font = Theme.fonts.heading },
	label = { size = 20, font = Theme.fonts.strong },
	body = { size = 20, font = Theme.fonts.body },
	-- Telefonda ~11 px: bunun altına inilmez.
	small = { size = 17, font = Theme.fonts.body },
}

function Kit.text(
	parent: Instance?,
	text: string,
	style: TextStyle,
	color: Color3?,
	size: UDim2?,
	order: number?
): TextLabel
	local spec = TEXT_STYLES[style]
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.FontFace = spec.font
	l.TextSize = spec.size
	l.TextColor3 = color or Theme.colors.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.TextWrapped = true
	l.Size = size or UDim2.new(1, 0, 0, spec.size + 6)
	l.LayoutOrder = order or 0
	l.Parent = parent
	return l
end

-- Yüksekliği metne göre uzayan paragraf.
function Kit.paragraph(parent: Instance?, text: string, style: TextStyle, color: Color3?): TextLabel
	local l = Kit.text(parent, text, style, color, UDim2.fromScale(1, 0))
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.TextYAlignment = Enum.TextYAlignment.Top
	return l
end

function Kit.icon(parent: Instance?, image: string, size: number, order: number?): ImageLabel
	local i = Instance.new("ImageLabel")
	i.BackgroundTransparency = 1
	i.Image = image
	i.ScaleType = Enum.ScaleType.Fit
	i.Size = UDim2.fromOffset(size, size)
	i.LayoutOrder = order or 0
	i.Parent = parent
	return i
end

-- Panel: koyu lacivert kart. `glass` haritanın üstündeki öğeler için hafif saydam.
function Kit.panel(parent: Instance?, size: UDim2, glass: boolean?, radius: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BackgroundTransparency = if glass then 0.06 else 0
	f.BorderSizePixel = 0
	f.Size = size
	f.Active = true
	Kit.corner(f, radius or 16)
	Kit.stroke(f, Theme.colors.stroke, 1.5)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(Theme.colors.panelRaised, Theme.colors.panel)
	g.Rotation = 90
	g.Parent = f
	f.Parent = parent
	return f
end

-- İç kart (panelin içindeki satır, ikon yuvası).
function Kit.well(parent: Instance?, size: UDim2, order: number?, radius: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Theme.colors.well
	f.BorderSizePixel = 0
	f.Size = size
	f.LayoutOrder = order or 0
	Kit.corner(f, radius or 12)
	f.Parent = parent
	return f
end

export type ButtonVariant = "gold" | "green" | "navy" | "red"

local VARIANTS: { [ButtonVariant]: { face: Color3, lip: Color3, text: Color3 } } = {
	gold = { face = Theme.colors.gold, lip = Theme.colors.goldLip, text = Theme.colors.onGold },
	green = { face = Theme.colors.green, lip = Theme.colors.greenLip, text = Theme.colors.text },
	navy = { face = Theme.colors.navy, lip = Theme.colors.navyLip, text = Theme.colors.text },
	red = { face = Theme.colors.alert, lip = Theme.colors.alertLip, text = Theme.colors.text },
}
local DISABLED = {
	face = Theme.colors.navyLip,
	lip = Theme.colors.background,
	text = Theme.colors.muted,
}

local LIP = 5

export type ButtonOptions = {
	text: string?,
	variant: ButtonVariant?,
	size: UDim2,
	icon: string?,
	iconSize: number?,
	textSize: number?,
	order: number?,
	enabled: boolean?,
	name: string?,
	onClick: (() -> ())?,
}

export type Button = {
	root: TextButton,
	label: TextLabel?,
	setText: (text: string) -> (),
	setEnabled: (enabled: boolean) -> (),
	setVariant: (variant: ButtonVariant) -> (),
	setOnClick: (callback: (() -> ())?) -> (),
}

-- Kalın alt kenarlı düğme: basınca yüz kenara iner.
function Kit.button(parent: Instance?, options: ButtonOptions): Button
	local variant: ButtonVariant = options.variant or "navy"
	local enabled = options.enabled ~= false
	local onClick = options.onClick

	local root = Instance.new("TextButton")
	root.Name = options.name or "Button"
	root.Text = ""
	root.AutoButtonColor = false
	root.BackgroundColor3 = VARIANTS[variant].lip
	root.BorderSizePixel = 0
	root.Size = options.size
	root.LayoutOrder = options.order or 0
	Kit.corner(root, 14)

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.BorderSizePixel = 0
	face.BackgroundColor3 = VARIANTS[variant].face
	face.Size = UDim2.new(1, 0, 1, -LIP)
	Kit.corner(face, 14)
	face.Parent = root
	-- Üstte ince parlaklık: düz renk yerine dokunulabilir yüzey.
	local shine = Instance.new("UIGradient")
	shine.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(216, 216, 216))
	shine.Rotation = 90
	shine.Parent = face

	local row = Kit.box(face, UDim2.fromScale(1, 1))
	Kit.list(row, {
		horizontal = true,
		gap = 8,
		alignX = Enum.HorizontalAlignment.Center,
		alignY = Enum.VerticalAlignment.Center,
	})
	if options.icon then
		Kit.icon(row, options.icon, options.iconSize or 26, 1)
	end
	local label: TextLabel? = nil
	if options.text ~= nil then
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.AutomaticSize = Enum.AutomaticSize.X
		l.Size = UDim2.fromScale(0, 1)
		l.LayoutOrder = 2
		l.FontFace = Theme.fonts.heading
		l.TextSize = options.textSize or 20
		l.Text = options.text
		l.Parent = row
		label = l
	end

	local function paint()
		local v = if enabled then VARIANTS[variant] else DISABLED
		root.BackgroundColor3 = v.lip
		face.BackgroundColor3 = v.face
		if label then
			label.TextColor3 = v.text
		end
		root.Active = enabled
	end
	paint()

	local function press(down: boolean)
		if not enabled then
			return
		end
		local info = TweenInfo.new(if down then 0.05 else 0.09, Enum.EasingStyle.Quad)
		TweenService:Create(face, info, {
			Position = if down then UDim2.fromOffset(0, LIP - 1) else UDim2.new(),
		}):Play()
	end
	root.MouseButton1Down:Connect(function()
		press(true)
	end)
	root.MouseButton1Up:Connect(function()
		press(false)
	end)
	root.MouseLeave:Connect(function()
		press(false)
	end)
	root.Activated:Connect(function()
		if enabled and onClick then
			Audio.play("click")
			onClick()
		end
	end)
	root.Parent = parent

	return {
		root = root,
		label = label,
		setText = function(text: string)
			if label then
				label.Text = text
			end
		end,
		setEnabled = function(value: boolean)
			enabled = value
			paint()
		end,
		setVariant = function(value: ButtonVariant)
			variant = value
			paint()
		end,
		setOnClick = function(callback: (() -> ())?)
			onClick = callback
		end,
	}
end

-- Kare ikon düğmesi (üst sıra, kamera).
function Kit.iconButton(
	parent: Instance?,
	image: string,
	size: number,
	onClick: () -> (),
	order: number?,
	name: string?
): Button
	return Kit.button(parent, {
		variant = "navy",
		size = UDim2.fromOffset(size, size),
		icon = image,
		iconSize = math.floor(size * 0.62),
		onClick = onClick,
		order = order,
		name = name,
	})
end

-- Yuvarlak bilgi hapı. Döner: dış çerçeve + metin.
function Kit.pill(
	parent: Instance?,
	icon: string?,
	text: string,
	color: Color3?,
	height: number?,
	order: number?
): (Frame, TextLabel)
	local h = height or 40
	local f = Instance.new("Frame")
	f.AutomaticSize = Enum.AutomaticSize.X
	f.Size = UDim2.fromOffset(0, h)
	f.BackgroundColor3 = Theme.colors.well
	f.BorderSizePixel = 0
	f.LayoutOrder = order or 0
	Kit.corner(f, math.floor(h / 2))
	Kit.stroke(f, Theme.colors.stroke, 1.5)
	Kit.padding(f, 0, 16, 0, if icon then 8 else 16)
	Kit.list(f, { horizontal = true, gap = 8, alignY = Enum.VerticalAlignment.Center })
	if icon then
		Kit.icon(f, icon, h - 12, 1)
	end
	local l = Kit.text(f, text, "heading", color, UDim2.fromOffset(0, h), 2)
	l.AutomaticSize = Enum.AutomaticSize.X
	l.TextSize = math.floor(h * 0.48)
	l.TextWrapped = false
	f.Parent = parent
	return f, l
end

export type Progress = { root: Frame, set: (fraction: number) -> () }

function Kit.progress(parent: Instance?, size: UDim2, color: Color3?, order: number?): Progress
	local track = Instance.new("Frame")
	track.BackgroundColor3 = Theme.colors.navyLip
	track.BorderSizePixel = 0
	track.Size = size
	track.LayoutOrder = order or 0
	Kit.corner(track, 100)
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = color or Theme.colors.green
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	Kit.corner(fill, 100)
	fill.Parent = track
	track.Parent = parent
	return {
		root = track,
		set = function(fraction: number)
			fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
		end,
	}
end

-- Yatay kaydırıcı (0–1, %5 adımlı). Fare ve dokunmatikle sürüklenir; `set` sürerken, `release`
-- parmak kalkınca çağrılır (kalıcı kayıt gibi pahalı işler için). Döner: kök düğme + yenile.
function Kit.slider(
	parent: Instance?,
	size: UDim2,
	get: () -> number,
	set: (value: number) -> (),
	release: (() -> ())?,
	order: number?
): (TextButton, () -> ())
	local root = Instance.new("TextButton")
	root.Name = "Slider"
	root.Text = ""
	root.AutoButtonColor = false
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = size
	root.LayoutOrder = order or 0

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.fromScale(0, 0.5)
	track.Size = UDim2.new(1, 0, 0, 12)
	track.BackgroundColor3 = Theme.colors.navyLip
	track.BorderSizePixel = 0
	Kit.corner(track, 100)
	Kit.stroke(track, Theme.colors.stroke, 1)
	track.Parent = root

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Theme.colors.gold
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	Kit.corner(fill, 100)
	fill.Parent = track

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(28, 28)
	knob.BackgroundColor3 = Theme.colors.text
	knob.BorderSizePixel = 0
	Kit.corner(knob, 14)
	Kit.stroke(knob, Theme.colors.goldLip, 2)
	knob.Parent = track

	local function paint()
		local value = math.clamp(get(), 0, 1)
		fill.Size = UDim2.fromScale(value, 1)
		knob.Position = UDim2.fromScale(value, 0.5)
	end

	local dragging = false
	local function update(x: number)
		local width = track.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local value = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
		set(math.floor(value * 20 + 0.5) / 20)
		paint()
	end
	local function isPointer(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end
	root.InputBegan:Connect(function(input: InputObject)
		if isPointer(input) then
			dragging = true
			update(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if
			dragging
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			update(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if dragging and isPointer(input) then
			dragging = false
			if release then
				release()
			end
		end
	end)
	paint()
	root.Parent = parent
	return root, paint
end

-- Aç/kapa anahtarı.
function Kit.toggle(
	parent: Instance?,
	get: () -> boolean,
	set: (value: boolean) -> (),
	order: number?
): (TextButton, () -> ())
	local b = Instance.new("TextButton")
	b.Name = "Toggle"
	b.Text = ""
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Size = UDim2.fromOffset(72, 40)
	b.LayoutOrder = order or 0
	Kit.corner(b, 20)
	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.BackgroundColor3 = Theme.colors.text
	knob.BorderSizePixel = 0
	knob.Size = UDim2.fromOffset(30, 30)
	Kit.corner(knob, 15)
	knob.Parent = b
	local function refresh(animated: boolean)
		local on = get()
		b.BackgroundColor3 = if on then Theme.colors.gold else Theme.colors.navy
		local target = UDim2.new(0, if on then 37 else 5, 0.5, 0)
		if animated then
			TweenService:Create(knob, TweenInfo.new(0.12), { Position = target }):Play()
		else
			knob.Position = target
		end
	end
	b.Activated:Connect(function()
		Audio.play("click")
		set(not get())
		refresh(true)
	end)
	refresh(false)
	b.Parent = parent
	return b, function()
		refresh(true)
	end
end

export type Tabs = { root: Frame, select: (index: number) -> () }

-- Sekme çubuğu. `onSelect(index)` seçim değişince.
function Kit.tabs(
	parent: Instance?,
	names: { string },
	onSelect: (index: number) -> (),
	order: number?
): Tabs
	local bar = Kit.well(parent, UDim2.new(1, 0, 0, 52), order, 14)
	Kit.padding(bar, 4)
	Kit.list(bar, { horizontal = true, gap = 4 })
	local buttons: { TextButton } = {}
	local function pick(index: number)
		for i, b in buttons do
			local on = i == index
			b.BackgroundTransparency = if on then 0 else 1
			b.TextColor3 = if on then Theme.colors.text else Theme.colors.muted
		end
	end
	for i, name in names do
		local b = Instance.new("TextButton")
		b.Name = "Tab" .. i
		b.AutoButtonColor = false
		b.BackgroundColor3 = Theme.colors.navy
		b.BorderSizePixel = 0
		b.FontFace = Theme.fonts.heading
		b.TextSize = 18
		b.Text = name
		b.LayoutOrder = i
		b.Size = UDim2.new(1 / #names, -4, 1, 0)
		Kit.corner(b, 11)
		b.Parent = bar
		b.Activated:Connect(function()
			Audio.play("click")
			pick(i)
			onSelect(i)
		end)
		table.insert(buttons, b)
	end
	pick(1)
	return { root = bar, select = pick }
end

-- Dikey kaydırma alanı: içerik uzadıkça tuval büyür (telefonda da taşmaz).
function Kit.scroll(parent: Instance?, size: UDim2, gap: number?): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = size
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.ScrollingDirection = Enum.ScrollingDirection.Y
	s.ScrollBarThickness = 5
	s.ScrollBarImageColor3 = Theme.colors.stroke
	s.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	Kit.list(s, { gap = gap or 10 })
	-- Seçili satırın çerçevesi dışa taşar; pay olmazsa kaydırma alanı sol kenarı keser.
	Kit.padding(s, 3)
	s.Parent = parent
	return s
end

export type Modal = {
	screen: ScreenGui,
	panel: Frame,
	header: Frame,
	body: Frame,
	open: () -> (),
	close: () -> (),
	isOpen: () -> boolean,
	onClosed: (callback: () -> ()) -> (),
}

export type ModalOptions = {
	name: string,
	title: string,
	icon: string?,
	size: Vector2,
	order: number?,
	bodyPadding: number?,
}

-- Ortak pencere: karartılmış arka plan, başlık, kapat düğmesi. Arka plana dokununca kapanır.
function Kit.modal(options: ModalOptions): Modal
	local screen = Kit.screen(options.name, options.order or 50, true)
	screen.Enabled = false

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Theme.colors.background
	dim.BackgroundTransparency = 0.3
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = screen

	local panel = Kit.panel(screen, UDim2.fromOffset(options.size.X, options.size.Y), false, 20)
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.ZIndex = 2
	Kit.scaled(panel)
	local pop = Instance.new("UIScale")
	pop.Parent = panel

	local header = Kit.box(panel, UDim2.new(1, 0, 0, 72))
	header.Name = "Header"
	Kit.padding(header, 0, 16, 0, 22)
	Kit.list(header, { horizontal = true, gap = 12, alignY = Enum.VerticalAlignment.Center })
	if options.icon then
		Kit.icon(header, options.icon, 40, 1)
	end
	local title = Kit.text(header, options.title, "title", nil, UDim2.new(0.6, 0, 1, 0), 2)
	title.Name = "Title"
	title.TextWrapped = false

	local rule = Instance.new("Frame")
	rule.BackgroundColor3 = Theme.colors.stroke
	rule.BackgroundTransparency = 0.5
	rule.BorderSizePixel = 0
	rule.Position = UDim2.fromOffset(0, 72)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.Parent = panel

	local body = Kit.box(panel, UDim2.new(1, 0, 1, -73))
	body.Name = "Body"
	body.Position = UDim2.fromOffset(0, 73)
	Kit.padding(body, options.bodyPadding or 20)

	local closedCallbacks: { () -> () } = {}
	local isOpen = false
	local function close()
		if not isOpen then
			return
		end
		isOpen = false
		screen.Enabled = false
		for _, callback in closedCallbacks do
			callback()
		end
	end
	local function open()
		isOpen = true
		screen.Enabled = true
		pop.Scale = 0.94
		TweenService:Create(
			pop,
			TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	end

	local closeButton = Kit.iconButton(nil, "", 48, close, 0, "Close")
	closeButton.root.AnchorPoint = Vector2.new(1, 0)
	closeButton.root.Position = UDim2.new(1, -14, 0, 12)
	local x = Kit.text(closeButton.root, "×", "title", nil, UDim2.new(1, 0, 1, -LIP))
	x.TextXAlignment = Enum.TextXAlignment.Center
	x.ZIndex = 3
	closeButton.root.Parent = panel

	dim.Activated:Connect(close)
	Kit.mount(screen)
	return {
		screen = screen,
		panel = panel,
		header = header,
		body = body,
		open = open,
		close = close,
		isOpen = function(): boolean
			return isOpen
		end,
		onClosed = function(callback: () -> ())
			table.insert(closedCallbacks, callback)
		end,
	}
end

-- Kule modelinin küçük önizlemesi (gerçek 3D model; kutu görsel yok). `templates` yoksa boş kalır.
function Kit.towerPreview(
	parent: Instance?,
	towerName: string,
	size: number,
	order: number?
): ViewportFrame
	local view = Instance.new("ViewportFrame")
	view.BackgroundTransparency = 1
	view.BorderSizePixel = 0
	view.Size = UDim2.fromOffset(size, size)
	view.LayoutOrder = order or 0
	view.Ambient = Color3.fromRGB(190, 190, 190)
	view.LightColor = Color3.fromRGB(255, 250, 240)
	view.LightDirection = Vector3.new(-1, -2, -1)
	local folder = game:GetService("ReplicatedStorage"):FindFirstChild("TowerMeshes")
	local template = if folder then folder:FindFirstChild(towerName) else nil
	if template and template:IsA("BasePart") then
		local part = template:Clone()
		part.CFrame = CFrame.new()
		part.Anchored = true
		part.Parent = view
		local camera = Instance.new("Camera")
		local extent = part.Size.Magnitude
		camera.FieldOfView = 26
		camera.CFrame = CFrame.lookAt(Vector3.new(1, 0.9, 1).Unit * extent * 2.1, Vector3.zero)
		camera.Parent = view
		view.CurrentCamera = camera
	end
	view.Parent = parent
	return view
end

return Kit
