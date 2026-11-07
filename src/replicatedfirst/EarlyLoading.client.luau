--!strict
-- Erken yükleme ekranı: Roblox'un kendi yükleme ekranını kaldırır ve oyun betikleri (StarterPlayer)
-- gelene kadar CROWNVIA logosunu gösterir. Ana yükleme ekranı (`src/client/LoadingScreen.luau`)
-- görününce bu ekran solup kalkar; böylece oyuncu hiçbir anda Roblox'un genel ekranını ya da boş
-- ekranı görmez. Bu betik ReplicatedFirst'te tek başına çalışır: `Kit`/`Theme` gibi istemci
-- modülleri henüz yok, o yüzden renkler ve logo kimliği burada yinelenir (`Icons.logo`, `Theme`).
-- Ana betikler hiç gelmezse (ağ/hata) TIMEOUT sonunda ekran kendiliğinden kalkar.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

-- `Icons.logo` ve `Icons.LOGO_ASPECT` ile aynı.
local LOGO = "rbxassetid://121024616572345"
local LOGO_ASPECT = 1024 / 358
-- `Icons.loadingArt` ile aynı: ana yükleme ekranının arka planı.
local ART = "rbxassetid://78052356744975"
local ART_OVERSCAN = 1.12
-- `Theme.colors` (background, gold, muted) ile aynı.
local TOP = Color3.fromRGB(24, 38, 74)
local BOTTOM = Color3.fromRGB(8, 13, 26)
local GLOW = Color3.fromRGB(255, 188, 96)
local MUTED = Color3.fromRGB(156, 172, 206)

-- Ana yükleme ekranı (DisplayOrder 100) bunun altında kalır; bu ekran onu görünce solar.
local DISPLAY_ORDER = 150
local MAIN_SCREEN = "LoadingScreen"
local TIMEOUT = 45
local FADE_SECS = 0.35
-- `Kit.scale` ile aynı tasarım ölçüsü (1040x620, 0,56–1,35).
local DESIGN_WIDTH = 1040
local DESIGN_HEIGHT = 620

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local screen = Instance.new("ScreenGui")
screen.Name = "EarlyLoading"
screen.DisplayOrder = DISPLAY_ORDER
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local back = Instance.new("CanvasGroup")
back.Name = "Back"
back.Size = UDim2.fromScale(1, 1)
back.BackgroundTransparency = 1
back.BorderSizePixel = 0
back.Parent = screen

local ground = Instance.new("Frame")
ground.Name = "Ground"
ground.Size = UDim2.fromScale(1, 1)
ground.BackgroundColor3 = Color3.new(1, 1, 1)
ground.BorderSizePixel = 0
ground.Parent = back
local gradient = Instance.new("UIGradient")
gradient.Color = ColorSequence.new(TOP, BOTTOM)
gradient.Rotation = 90
gradient.Parent = ground

-- Ana ekranla aynı arka plan: görsel inince açılır, üstünde lacivert tül.
local art = Instance.new("ImageLabel")
art.Name = "Art"
art.BackgroundTransparency = 1
art.Image = ART
art.ImageTransparency = 1
art.ScaleType = Enum.ScaleType.Crop
art.AnchorPoint = Vector2.new(0.5, 0.5)
art.Position = UDim2.fromScale(0.5, 0.5)
art.Size = UDim2.fromScale(ART_OVERSCAN, ART_OVERSCAN)
art.Parent = back
local tint = Instance.new("Frame")
tint.Name = "Tint"
tint.Size = UDim2.fromScale(1, 1)
tint.BackgroundColor3 = BOTTOM
tint.BackgroundTransparency = 0.45
tint.BorderSizePixel = 0
tint.Parent = back

local function scaleFor(): number
	local size = screen.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return 1
	end
	return math.clamp(math.min(size.Y / DESIGN_HEIGHT, size.X / DESIGN_WIDTH), 0.56, 1.35)
end

-- Logonun arkasında yumuşak ışıltı (ana ekranla aynı, daha az daire).
local scales: { UIScale } = {}
for step = 0, 7 do
	local diameter = 1000 - (1000 - 260) * step / 7
	local glow = Instance.new("Frame")
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.44)
	glow.Size = UDim2.fromOffset(diameter, diameter)
	glow.BackgroundColor3 = GLOW
	glow.BackgroundTransparency = 0.975
	glow.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, diameter)
	corner.Parent = glow
	local scale = Instance.new("UIScale")
	scale.Parent = glow
	table.insert(scales, scale)
	glow.Parent = back
end

local column = Instance.new("Frame")
column.Name = "Column"
column.AnchorPoint = Vector2.new(0.5, 0.5)
column.Position = UDim2.fromScale(0.5, 0.5)
column.Size = UDim2.fromOffset(460, 0)
column.AutomaticSize = Enum.AutomaticSize.Y
column.BackgroundTransparency = 1
column.BorderSizePixel = 0
column.Parent = back
local columnScale = Instance.new("UIScale")
columnScale.Parent = column
table.insert(scales, columnScale)
local list = Instance.new("UIListLayout")
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Padding = UDim.new(0, 14)
list.HorizontalAlignment = Enum.HorizontalAlignment.Center
list.Parent = column

local logoHeight = math.floor(420 / LOGO_ASPECT)
local holder = Instance.new("Frame")
holder.LayoutOrder = 1
holder.Size = UDim2.fromOffset(420, logoHeight + 14)
holder.BackgroundTransparency = 1
holder.BorderSizePixel = 0
holder.Parent = column
local logo = Instance.new("ImageLabel")
logo.Name = "Logo"
logo.AnchorPoint = Vector2.new(0.5, 0.5)
logo.Position = UDim2.fromScale(0.5, 0.5)
logo.Size = UDim2.fromOffset(420, logoHeight)
logo.BackgroundTransparency = 1
logo.Image = LOGO
logo.ScaleType = Enum.ScaleType.Fit
logo.Parent = holder

local label = Instance.new("TextLabel")
label.LayoutOrder = 2
label.Size = UDim2.new(1, 0, 0, 26)
label.BackgroundTransparency = 1
label.FontFace = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.SemiBold)
label.TextSize = 20
label.TextColor3 = MUTED
label.Text = "Loading"
label.Parent = column

local function rescale()
	local value = scaleFor()
	for _, scale in scales do
		scale.Scale = value
	end
end
screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)

screen.Parent = playerGui
rescale()
-- Kendi ekranımız çizildikten sonra Roblox'unkini kaldır (arada boşluk kalmasın).
ReplicatedFirst:RemoveDefaultLoadingScreen()

-- Logo hızlı gelsin: ana betiklerin yükleme ekranı da aynı görseli kullanır.
task.spawn(function()
	pcall(function()
		ContentProvider:PreloadAsync({ logo })
	end)
	pcall(function()
		ContentProvider:PreloadAsync({ art })
	end)
	TweenService:Create(art, TweenInfo.new(0.8), { ImageTransparency = 0 }):Play()
end)

-- Hafif süzülme: ana ekrandaki logo hareketine yakın.
TweenService:Create(
	logo,
	TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Position = UDim2.new(0.5, 0, 0.5, 5) }
):Play()

local closing = false
local function close()
	if closing then
		return
	end
	closing = true
	TweenService:Create(back, TweenInfo.new(FADE_SECS), { GroupTransparency = 1 }):Play()
	task.delay(FADE_SECS + 0.05, function()
		screen:Destroy()
	end)
end

-- Ana yükleme ekranı çizilince (StarterPlayerScripts) bu ekran solar; o zamana kadar üstte kalır.
local function watch(child: Instance)
	if child.Name == MAIN_SCREEN then
		-- Ana ekranın ilk karesi otursun, sonra çapraz solma.
		task.delay(0.15, close)
	end
end
playerGui.ChildAdded:Connect(watch)
local existing = playerGui:FindFirstChild(MAIN_SCREEN)
if existing then
	watch(existing)
end
task.delay(TIMEOUT, close)
