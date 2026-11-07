--!strict
-- Ödül anları: kral düşürme, fetih serisi, sıralama atlama, yeni rekor, intikam, seri sandığı. Yalnız
-- gösterim ve ses; kurala dokunmaz. Olaylar sunucudan gelir (`AccountView.reward`), sıralama atlama
-- lider tablosundan. Sandığın içeriği önceden yazar ve sabittir, rastgele ödül yok.

local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticArt = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Art"):WaitForChild("CosmeticArt")
)

local Audio = require(script.Parent.Audio)
local Camera = require(script.Parent.Camera)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local Hype = {}

local BANNER_SECS = 2.2
local COMBO_SECS = 2.5
local COINS = 26

local screen: ScreenGui? = nil
local bannerToken = 0
local comboToken = 0
local chest: Kit.Modal? = nil
local chestImage: ImageLabel? = nil
local chestTitle: TextLabel? = nil
local chestAmount: TextLabel? = nil

local function gui(): ScreenGui
	local existing = screen
	if existing then
		return existing
	end
	local created = Kit.screen("Hype", 35, true)
	Kit.mount(created)
	screen = created
	return created
end

local function pop(target: GuiObject, from: number)
	local s = target:FindFirstChildOfClass("UIScale") :: UIScale?
	if s == nil then
		local created = Instance.new("UIScale")
		created.Parent = target
		s = created
	end
	local scale = s :: UIScale
	scale.Scale = from
	TweenService:Create(
		scale,
		TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }
	):Play()
end

-- Ortada büyük yazı + alt satır.
function Hype.banner(title: string, sub: string?, color: Color3?)
	local parent = gui()
	local old = parent:FindFirstChild("Banner")
	if old then
		old:Destroy()
	end
	bannerToken += 1
	local token = bannerToken
	local frame = Kit.box(parent, UDim2.fromOffset(860, 130))
	frame.Name = "Banner"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.3)
	Kit.scaled(frame)
	Kit.list(frame, { gap = 2, alignX = Enum.HorizontalAlignment.Center })
	local big =
		Kit.text(frame, title, "display", color or Theme.colors.gold, UDim2.new(1, 0, 0, 84), 1)
	big.TextXAlignment = Enum.TextXAlignment.Center
	big.TextWrapped = false
	big.TextSize = 62
	big.TextStrokeTransparency = 0.2
	big.TextStrokeColor3 = Theme.colors.background
	if sub then
		local small = Kit.text(frame, sub, "heading", Theme.colors.text, UDim2.new(1, 0, 0, 36), 2)
		small.TextXAlignment = Enum.TextXAlignment.Center
		small.TextWrapped = false
		small.TextStrokeTransparency = 0.3
		small.TextStrokeColor3 = Theme.colors.background
	end
	pop(frame, 0.55)
	task.delay(BANNER_SECS, function()
		if token == bannerToken then
			frame:Destroy()
		end
	end)
end

-- Ekrandan süzülen Credits paraları.
function Hype.coins()
	local parent = gui()
	local random = Random.new()
	for _ = 1, COINS do
		local coin = Instance.new("ImageLabel")
		coin.BackgroundTransparency = 1
		coin.Image = Icons.ui.coin
		coin.AnchorPoint = Vector2.new(0.5, 0.5)
		local size = random:NextInteger(22, 46)
		coin.Size = UDim2.fromOffset(size, size)
		local x = random:NextNumber(0.08, 0.92)
		coin.Position = UDim2.fromScale(x, -0.08)
		coin.Rotation = random:NextInteger(0, 360)
		coin.Parent = parent
		local secs = random:NextNumber(0.9, 1.7)
		local tween = TweenService:Create(
			coin,
			TweenInfo.new(secs, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{
				Position = UDim2.fromScale(x + random:NextNumber(-0.08, 0.08), 1.1),
				Rotation = coin.Rotation + random:NextInteger(180, 720),
			}
		)
		tween:Play()
		task.delay(secs, function()
			coin:Destroy()
		end)
	end
end

local function flash(color: Color3)
	local parent = gui()
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 0.45
	frame.BorderSizePixel = 0
	frame.Parent = parent
	TweenService:Create(frame, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
	task.delay(0.5, function()
		frame:Destroy()
	end)
end

function Hype.kingSlain(reward: number)
	flash(Theme.colors.gold)
	Camera.kick(0.7)
	Audio.play("kingSlain")
	Hype.coins()
	Hype.banner(Strings.kingSlain, string.format(Strings.plusCredits, reward))
end

function Hype.newBest(score: number)
	Audio.play("newBest")
	Hype.coins()
	Hype.banner(Strings.newBestBanner, string.format(Strings.scoreLine, score))
end

function Hype.revenge(reward: number)
	Audio.play("kingSlain")
	Hype.coins()
	Hype.banner(Strings.revenge, string.format(Strings.plusCredits, reward), Theme.colors.danger)
end

function Hype.rankUp(alias: string?, rank: number)
	if rank == 1 then
		Audio.play("newBest")
		Hype.coins()
		Hype.banner(Strings.rankFirst, nil)
		return
	end
	Audio.playPitched("upgrade", 1.15)
	local text = if alias
		then string.format(Strings.rankPassed, alias, rank)
		else string.format(Strings.rankNow, rank)
	Hype.banner(text, nil, Theme.colors.text)
end

-- Fetih serisi: üst ortada x sayacı, ses perdesi yükselir.
function Hype.combo(count: number, reward: number)
	local parent = gui()
	local old = parent:FindFirstChild("Combo")
	if old then
		old:Destroy()
	end
	comboToken += 1
	local token = comboToken
	local label = Kit.text(parent, "", "display", Theme.colors.gold, UDim2.fromOffset(420, 70))
	label.Name = "Combo"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, 92)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextWrapped = false
	label.TextSize = math.min(38 + count * 2, 60)
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Theme.colors.background
	label.Text = if reward > 0
		then string.format(Strings.comboReward, count, reward)
		else string.format(Strings.combo, count)
	Kit.scaled(label)
	pop(label, 0.6)
	Audio.playPitched("capture", math.min(1 + count * 0.07, 1.8))
	task.delay(COMBO_SECS, function()
		if token == comboToken then
			label:Destroy()
		end
	end)
end

local function buildChest(): Kit.Modal
	local m = Kit.modal({
		name = "StreakChest",
		title = Strings.chestTitle,
		size = Vector2.new(460, 430),
		order = 56,
	})
	Kit.list(m.body, { gap = 10, alignX = Enum.HorizontalAlignment.Center })
	local image = Kit.icon(m.body, CosmeticArt.creditPacks.credits_starter, 170, 1)
	local title = Kit.text(m.body, "", "heading", nil, UDim2.new(1, 0, 0, 30), 2)
	title.TextXAlignment = Enum.TextXAlignment.Center
	local amount = Kit.text(m.body, "", "title", Theme.colors.gold, UDim2.new(1, 0, 0, 40), 3)
	amount.TextXAlignment = Enum.TextXAlignment.Center
	Kit.button(m.body, {
		variant = "gold",
		text = Strings.chestClaim,
		textSize = 22,
		size = UDim2.new(1, 0, 0, 66),
		order = 4,
		name = "Claim",
		onClick = function()
			m.close()
			Hype.coins()
		end,
	})
	chestImage = image
	chestTitle = title
	chestAmount = amount
	return m
end

-- Seri sandığı: titrer, açılır, sayı döner. Miktar sunucuda zaten hesaba geçti.
function Hype.chest(day: number, amount: number)
	local m: Kit.Modal = chest or buildChest()
	chest = m
	m.open()
	local image = chestImage :: ImageLabel
	local label = chestAmount :: TextLabel
	(chestTitle :: TextLabel).Text = string.format(Strings.chestDay, day)
	label.Text = "0"
	task.spawn(function()
		for i = 1, 6 do
			image.Rotation = if i % 2 == 0 then 6 else -6
			task.wait(0.07)
		end
		image.Rotation = 0
		Audio.play("chestOpen")
		pop(image, 1.3)
		Hype.rollNumber(label, amount, "+%d")
	end)
end

-- Sayı dönerek yükselir, tıkırtıyla (ödül sesi).
function Hype.rollNumber(label: TextLabel, target: number, format: string)
	local steps = math.clamp(target, 1, 14)
	task.spawn(function()
		for i = 1, steps do
			label.Text = string.format(format, math.floor(target * i / steps))
			Audio.playPitched("click", 0.9 + i * 0.05)
			task.wait(0.05)
		end
	end)
end

return Hype
