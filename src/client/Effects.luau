--!strict
-- Kule efektleri: ele geçirme dalgası, yükseltme kıvılcımı. Yalnız görsel; sonucu sunucu verisi
-- belirler (efekt, istemcinin gördüğü sahiplik/tip değişiminde oynar).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ProjectileArt = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Art"):WaitForChild("ProjectileArt")
)

local CosmeticArt = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Art"):WaitForChild("CosmeticArt")
)

local Theme = require(script.Parent.Theme)

local Effects = {}

local FX = ProjectileArt.fx

local function holder(at: Vector3, parent: Instance): Attachment
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = Vector3.one
	part.Position = at
	part.Parent = parent
	local attachment = Instance.new("Attachment")
	attachment.Parent = part
	task.delay(3, function()
		part:Destroy()
	end)
	return attachment
end

local function emitter(
	parent: Attachment,
	texture: string,
	color: Color3,
	size: NumberSequence,
	lifetime: NumberRange,
	speed: NumberRange,
	flat: boolean
): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = texture
	e.Color = ColorSequence.new(color)
	e.Size = size
	e.Lifetime = lifetime
	e.Speed = speed
	e.LightEmission = 1
	e.Transparency = NumberSequence.new(0, 1)
	e.Enabled = false
	if flat then
		e.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
		e.EmissionDirection = Enum.NormalId.Top
	else
		e.SpreadAngle = Vector2.new(60, 60)
		e.EmissionDirection = Enum.NormalId.Top
		e.Acceleration = Vector3.new(0, -12, 0)
	end
	e.Parent = parent
	return e
end

-- Sahiplik değişti: yeni sahibin renginde yere yayılan halka + kıvılcım.
-- `style`: yeni sahibin kozmetik fetih efekti (docs/HESAP_MAGAZA.md). Renk her zaman sahip rengi,
-- süre kısa, kule ve sayı rozetinin altında kalır (okunurluk).
function Effects.capture(at: Vector3, color: Color3, parent: Instance, style: string?)
	local a = holder(at + Vector3.new(0, 0.5, 0), parent)
	if style == "victory_ring" then
		-- Defne halkası + altın kıvılcım.
		emitter(
			a,
			CosmeticArt.images.victory_ring,
			color:Lerp(Color3.new(1, 1, 1), 0.25),
			NumberSequence.new(3, 13),
			NumberRange.new(0.8),
			NumberRange.new(0.01),
			true
		):Emit(1)
		emitter(
			a,
			FX.spark,
			Theme.colors.crown,
			NumberSequence.new(0.6, 0),
			NumberRange.new(0.5, 0.8),
			NumberRange.new(5, 9),
			false
		):Emit(10)
	elseif style == "banner_seal" then
		-- Yere basılan mühür: büyüyüp söner, ardından ince halka.
		emitter(
			a,
			CosmeticArt.images.banner_seal,
			color:Lerp(Color3.new(1, 1, 1), 0.2),
			NumberSequence.new(9, 11),
			NumberRange.new(1.1),
			NumberRange.new(0.01),
			true
		):Emit(1)
		emitter(
			a,
			FX.ring,
			color,
			NumberSequence.new(4, 14),
			NumberRange.new(0.7),
			NumberRange.new(0.01),
			true
		):Emit(1)
	elseif style == "chevron_strike" or style == "star_burst" then
		-- Yere basılan damga: ok başı ya da yıldız, ardından halka.
		emitter(
			a,
			CosmeticArt.images[style],
			color:Lerp(Color3.new(1, 1, 1), 0.2),
			NumberSequence.new(5, 10),
			NumberRange.new(0.9),
			NumberRange.new(0.01),
			true
		):Emit(1)
		emitter(
			a,
			FX.ring,
			color,
			NumberSequence.new(3, 13),
			NumberRange.new(0.6),
			NumberRange.new(0.01),
			true
		):Emit(1)
	else
		emitter(
			a,
			FX.ring,
			color,
			NumberSequence.new(2, 12),
			NumberRange.new(0.6),
			NumberRange.new(0.01),
			true
		):Emit(1)
	end
	emitter(
		a,
		FX.spark,
		color,
		NumberSequence.new(0.7, 0),
		NumberRange.new(0.4, 0.7),
		NumberRange.new(6, 10),
		false
	):Emit(12)
end

-- Yükseltme: altın kıvılcım yağmuru.
function Effects.upgrade(at: Vector3, parent: Instance)
	local a = holder(at + Vector3.new(0, 2, 0), parent)
	emitter(
		a,
		FX.spark,
		Theme.colors.gold,
		NumberSequence.new(0.9, 0),
		NumberRange.new(0.6, 1),
		NumberRange.new(5, 9),
		false
	):Emit(18)
end

-- Kulede çatışma: düşman birliği vardı ve savunma tuttu (sahip değişmedi). Toz + kıvılcım,
-- kule birim kaybettiyse yükselip sönen "-N". Sayı sunucu verisinden (iki delta arası fark).
function Effects.clash(at: Vector3, lost: number, parent: Instance)
	local a = holder(at + Vector3.new(0, 1.5, 0), parent)
	local dust = emitter(
		a,
		FX.smoke,
		Color3.fromRGB(196, 178, 150),
		NumberSequence.new(1.5, 4),
		NumberRange.new(0.5, 0.9),
		NumberRange.new(2, 4),
		false
	)
	dust.LightEmission = 0
	dust.Acceleration = Vector3.new(0, 2, 0)
	dust:Emit(6)
	emitter(
		a,
		FX.spark,
		Theme.colors.gold,
		NumberSequence.new(0.5, 0),
		NumberRange.new(0.25, 0.45),
		NumberRange.new(6, 11),
		false
	):Emit(8)
	if lost <= 0 then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(80, 36)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.Parent = a.Parent
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.FontFace = Theme.fonts.heading
	text.TextColor3 = Theme.colors.danger
	text.TextStrokeTransparency = 0.3
	text.Text = "-" .. lost
	text.Parent = gui
	local info = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffset = Vector3.new(0, 6, 0) }):Play()
	TweenService:Create(text, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
end

return Effects
