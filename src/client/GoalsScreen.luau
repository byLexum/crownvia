--!strict
-- Günlük hedefler (hesap ilerlemesi, Kiomet'te yok; `docs/HESAP_MAGAZA.md`): Credits bakiyesi, üç
-- hedef, Victor Frame ilerlemesi. Ödülleri sunucu verir; ekran yalnız gösterir.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Rewards = require(Shared:WaitForChild("Account"):WaitForChild("Rewards"))
local CosmeticArt = require(Shared:WaitForChild("Art"):WaitForChild("CosmeticArt"))

local AccountView = require(script.Parent.AccountView)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local GoalsScreen = {}

local GOAL_ICONS: { [string]: string } = {
	capture = Icons.ui.flag,
	upgrade = Icons.ui.tower,
	score = Icons.ui.trophy,
}

local modal: Kit.Modal? = nil
local list: GuiObject? = nil
local achievementsList: GuiObject? = nil
local streakLabel: TextLabel? = nil
local creditsLabel: TextLabel? = nil

local function goalText(goal: AccountView.Goal): string
	local template = if goal.kind == "capture"
		then Strings.goalCapture
		elseif goal.kind == "upgrade" then Strings.goalUpgrade
		else Strings.goalScore
	return string.format(template, goal.target)
end

local function progressRow(
	parent: Instance,
	order: number,
	icon: string,
	title: string,
	progress: number,
	target: number,
	done: boolean,
	reward: string
)
	local row = Kit.well(parent, UDim2.new(1, 0, 0, 84), order)
	Kit.padding(row, 0, 16, 0, 12)
	Kit.icon(row, if done then Icons.ui.check else icon, 56).Position = UDim2.fromOffset(0, 14)
	local center = Kit.box(row, UDim2.new(1, -196, 1, 0))
	center.Position = UDim2.fromOffset(70, 0)
	Kit.list(center, { gap = 6, alignY = Enum.VerticalAlignment.Center })
	local name = Kit.text(center, title, "label", nil, UDim2.new(1, 0, 0, 26), 1)
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local bar = Kit.progress(center, UDim2.new(1, 0, 0, 12), Theme.colors.gold, 2)
	bar.set(if target > 0 then progress / target else 0)
	local right = Kit.box(row, UDim2.new(0, 118, 1, 0))
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.fromScale(1, 0)
	Kit.list(right, {
		alignX = Enum.HorizontalAlignment.Right,
		alignY = Enum.VerticalAlignment.Center,
	})
	local count = Kit.text(
		right,
		string.format("%d/%d", math.min(progress, target), target),
		"small",
		Theme.colors.muted,
		UDim2.new(1, 0, 0, 24),
		1
	)
	count.TextXAlignment = Enum.TextXAlignment.Right
	local value = Kit.text(right, reward, "label", Theme.colors.gold, UDim2.new(1, 0, 0, 28), 2)
	value.TextXAlignment = Enum.TextXAlignment.Right
end

local ACHIEVEMENT_ICONS: { [string]: string } = {
	kings = Icons.crown,
	captures = Icons.ui.flag,
	upgrades = Icons.ui.tower,
	bestScore = Icons.ui.trophy,
}

local function renderStreak(profile: AccountView.Profile?)
	local label = streakLabel
	if label == nil then
		return
	end
	if profile == nil or profile.streak == 0 then
		label.Text = Strings.goalsHint
		return
	end
	local rewards = Rewards.STREAK_REWARDS
	label.Text = string.format(
		Strings.streakHint,
		profile.streak,
		rewards[math.min(profile.streak + 1, #rewards)]
	)
end

local function renderAchievements(profile: AccountView.Profile?)
	local frame = achievementsList
	if frame == nil then
		return
	end
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if profile == nil then
		return
	end
	-- Her tür için sıradaki hedef: liste kısa kalır, oyuncu bir sonraki adımı görür.
	local shown = 0
	for _, stat in { "kings", "captures", "upgrades", "bestScore" } do
		local nextGoal: Rewards.Achievement? = nil
		local last: Rewards.Achievement? = nil
		for _, a in Rewards.ACHIEVEMENTS do
			if a.stat == stat then
				last = a
				if nextGoal == nil and not profile.achievements[a.id] then
					nextGoal = a
				end
			end
		end
		local a = nextGoal or last
		if a then
			shown += 1
			local text = if a.stat == "kings" and a.target == 1
				then Strings.achievementFirstKing
				else string.format(Strings.achievementText[a.stat] or "%d", a.target)
			progressRow(
				frame,
				shown,
				ACHIEVEMENT_ICONS[a.stat] or Icons.ui.trophy,
				text,
				profile.stats[a.stat] or 0,
				a.target,
				profile.achievements[a.id] == true,
				string.format("+%d", a.reward)
			)
		end
	end
end

local function render()
	renderAchievements(AccountView.profile())
	renderStreak(AccountView.profile())
	local frame = list
	if frame == nil then
		return
	end
	local profile = AccountView.profile()
	if creditsLabel then
		creditsLabel.Text = if profile then tostring(profile.credits) else "..."
	end
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if profile == nil then
		Kit.paragraph(frame, Strings.storeUnavailable, "body", Theme.colors.muted)
		return
	end
	if #profile.goals == 0 then
		Kit.paragraph(frame, Strings.goalsEmpty, "body", Theme.colors.muted).LayoutOrder = 0
	end
	-- Yeni günlük hedefler UTC gece yarısı gelir (`Rewards.dayOf`).
	local untilNew = 86400 - os.time() % 86400
	local reset = Kit.text(
		frame,
		string.format(Strings.goalsReset, Kit.duration(untilNew)),
		"small",
		Theme.colors.muted,
		UDim2.new(1, 0, 0, 24),
		0
	)
	reset.TextXAlignment = Enum.TextXAlignment.Right
	for i, goal in profile.goals do
		progressRow(
			frame,
			i,
			GOAL_ICONS[goal.kind] or Icons.ui.goal,
			goalText(goal),
			goal.progress,
			goal.target,
			goal.done,
			string.format("+%d", Rewards.GOAL_REWARD)
		)
	end
	local head = Kit.text(frame, Strings.playSection, "heading", nil, UDim2.new(1, 0, 0, 36), 20)
	head.TextSize = 21
	for i, milestone in Rewards.PLAY_MILESTONES do
		progressRow(
			frame,
			20 + i,
			Icons.ui.flag,
			string.format(Strings.playGoal, milestone.minutes),
			profile.minutes,
			milestone.minutes,
			profile.minutes >= milestone.minutes,
			string.format("+%d", milestone.reward)
		)
	end
	progressRow(
		frame,
		30,
		CosmeticArt.previews[Rewards.PLAY_ITEM],
		Strings.itemNames[Rewards.PLAY_ITEM],
		profile.activeMinutes,
		Rewards.PLAY_ITEM_MINUTES,
		profile.owned[Rewards.PLAY_ITEM] == true,
		Strings.frameReward
	)
	Kit.paragraph(frame, Strings.playHint, "small", Theme.colors.muted).LayoutOrder = 31
	local captures = profile.captures
	progressRow(
		frame,
		10,
		CosmeticArt.previews.victor_frame,
		Strings.itemNames.victor_frame,
		captures,
		profile.frameCaptures,
		profile.owned[Rewards.FRAME_ITEM] == true,
		Strings.frameReward
	)
end

function GoalsScreen.init()
	if modal ~= nil then
		return
	end
	local m = Kit.modal({
		name = "Goals",
		title = Strings.dailyGoals,
		icon = Icons.ui.goal,
		size = Vector2.new(680, 540),
	})
	local pill, label = Kit.pill(m.panel, Icons.ui.coin, "0", Theme.colors.gold, 46)
	pill.AnchorPoint = Vector2.new(1, 0)
	pill.Position = UDim2.new(1, -74, 0, 13)
	creditsLabel = label
	local daily: GuiObject? = nil
	local achieved: GuiObject? = nil
	Kit.tabs(m.body, { Strings.dailyTab, Strings.achievementsTab }, function(index: number)
		(daily :: GuiObject).Visible = index == 1
		(achieved :: GuiObject).Visible = index == 2
	end)
	local scroll = Kit.scroll(m.body, UDim2.new(1, 0, 1, -94), 8)
	scroll.Position = UDim2.fromOffset(0, 62)
	daily = scroll
	local trophies = Kit.scroll(m.body, UDim2.new(1, 0, 1, -94), 8)
	trophies.Position = UDim2.fromOffset(0, 62)
	trophies.Visible = false
	achieved = trophies
	achievementsList = trophies
	local hint = Kit.text(m.body, Strings.goalsHint, "small", Theme.colors.muted)
	streakLabel = hint
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.fromScale(0, 1)
	modal = m
	list = scroll
	AccountView.onProfileChanged(render)
	render()
end

function GoalsScreen.open()
	local m = modal
	if m then
		render()
		m.open()
	end
end

return GoalsScreen
