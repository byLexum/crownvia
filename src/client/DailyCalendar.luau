--!strict
-- Günlük giriş ödülü takvimi (Kiomet'te yok; hesap katmanı, savaş kuralına dokunmaz).
-- Sunucu ödülü günün ilk girişinde zaten hesaba geçirir (`Rewards.onDayPlayed`); bu pencere
-- yalnız gösterir: haftanın 7 günü, geçmiş günler işaretli, bugün parlak, sandık günleri sandıklı.
-- Yükleme ekranı kalkana kadar bekler.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticArt = require(Shared:WaitForChild("Art"):WaitForChild("CosmeticArt"))
local Rewards = require(Shared:WaitForChild("Account"):WaitForChild("Rewards"))

local Audio = require(script.Parent.Audio)
local Hype = require(script.Parent.Hype)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local LoadingScreen = require(script.Parent.LoadingScreen)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local DailyCalendar = {}

local modal: Kit.Modal? = nil
local row: Frame? = nil
local hint: TextLabel? = nil

-- Serinin `count`. günü için (günlük ödül, sandık).
local function dayAmounts(count: number): (number, number)
	local list = Rewards.STREAK_REWARDS
	local reward = list[math.min(count, #list)]
	local weekDay = (count - 1) % 7 + 1
	return reward, Rewards.STREAK_CHESTS[weekDay] or 0
end

local function build(): Kit.Modal
	local m = Kit.modal({
		name = "DailyCalendar",
		title = Strings.dailyRewardTitle,
		icon = Icons.ui.coin,
		size = Vector2.new(860, 420),
		order = 56,
	})
	Kit.list(m.body, { gap = 14, alignX = Enum.HorizontalAlignment.Center })
	local days = Kit.box(m.body, UDim2.new(1, 0, 0, 200), 1)
	Kit.list(days, {
		gap = 10,
		horizontal = true,
		alignX = Enum.HorizontalAlignment.Center,
	})
	local note = Kit.text(m.body, "", "body", Theme.colors.muted, UDim2.new(1, 0, 0, 28), 2)
	note.TextXAlignment = Enum.TextXAlignment.Center
	Kit.button(m.body, {
		variant = "gold",
		text = Strings.chestClaim,
		textSize = 22,
		size = UDim2.new(0, 320, 0, 64),
		order = 3,
		name = "Claim",
		onClick = function()
			m.close()
			Hype.coins()
		end,
	})
	row = days
	hint = note
	return m
end

local function card(parent: Frame, weekDay: number, count: number, today: number)
	local reward, chest = dayAmounts(count)
	local past = weekDay < today
	local isToday = weekDay == today
	local c = Kit.well(parent, UDim2.new(0, 104, 1, 0), weekDay, 16)
	c.Name = "Day" .. weekDay
	Kit.padding(c, 10, 6, 10, 6)
	Kit.list(c, { gap = 4, alignX = Enum.HorizontalAlignment.Center })
	if isToday then
		c.BackgroundColor3 = Theme.colors.panelRaised
		Kit.stroke(c, Theme.colors.gold, 3)
	end
	local title = Kit.text(
		c,
		string.format(Strings.dayN, weekDay),
		"label",
		if isToday then Theme.colors.gold else Theme.colors.muted,
		UDim2.new(1, 0, 0, 22),
		1
	)
	title.TextXAlignment = Enum.TextXAlignment.Center
	local image = if chest > 0 then CosmeticArt.creditPacks.credits_starter else Icons.ui.coin
	local icon = Kit.icon(c, image, if chest > 0 then 92 else 70, 2)
	local amount = Kit.text(
		c,
		"+" .. (reward + chest),
		"heading",
		Theme.colors.gold,
		UDim2.new(1, 0, 0, 30),
		3
	)
	amount.TextXAlignment = Enum.TextXAlignment.Center
	if past then
		icon.ImageTransparency = 0.55
		amount.TextTransparency = 0.5
		local check = Kit.icon(c, Icons.ui.check, 34, 4)
		check.ImageColor3 = Theme.colors.gold
	end
	return amount
end

-- `count`: serinin bugünkü günü (1 = ilk gün). Miktar sunucuda zaten hesaba geçti.
function DailyCalendar.show(count: number)
	task.spawn(function()
		while LoadingScreen.isShowing() do
			task.wait(0.25)
		end
		local m: Kit.Modal = modal or build()
		modal = m
		local days = row :: Frame
		for _, child in days:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		local today = (count - 1) % 7 + 1
		local first = count - today + 1
		local todayAmount: TextLabel? = nil
		for weekDay = 1, 7 do
			local label = card(days, weekDay, first + weekDay - 1, today)
			if weekDay == today then
				todayAmount = label
			end
		end
		local tomorrowReward, tomorrowChest = dayAmounts(count + 1)
		local note = hint :: TextLabel
		note.Text = string.format(Strings.dailyTomorrow, tomorrowReward + tomorrowChest)
		m.open()
		local reward, chest = dayAmounts(count)
		Audio.play(if chest > 0 then "chestOpen" else "upgrade")
		if todayAmount then
			Hype.rollNumber(todayAmount, reward + chest, "+%d")
		end
	end)
end

return DailyCalendar
