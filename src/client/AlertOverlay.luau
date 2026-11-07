--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/ui/alert_overlay.rs

-- Uyarılar. Metinler bize ait, anlamları kaynaktaki `phrases.rs` ile aynı. Satıra dokununca kamera
-- ilgili kuleye gider; × satırı (bu yaşam boyunca) gizler.
-- Gösterim sırası kaynakla aynı: kral saldırı altında > kral güvende değil; sonra dolu, taşan, zombi.
-- Kral saldırı altındayken uyarı üst banttadır (kırmızı, ikon + metin, dokununca krala gider):
-- burada ikinci kez gösterilmez.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local Alerts = require(Sim.Alerts)
local Unit = require(Sim.Unit)

local Audio = require(script.Parent.Audio)
local ForceView = require(script.Parent.ForceView)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Nav = require(script.Parent.Nav)
local Theme = require(script.Parent.Theme)

local AlertOverlay = {}

type Row = {
	key: string,
	text: string,
	hint: string,
	icon: string,
	towerId: number?,
	dismissible: boolean,
}

local list: Frame? = nil
-- Bana gelen füzeler (`ForceView`): kapatılamaz, en üstte, kırmızı.
local missiles: { ForceView.Missile } = {}
local missileHint: TextLabel? = nil
local missileTitle = ""
local onPanTo: ((number) -> ())? = nil
local current: Alerts.Alerts? = nil
-- `use_dismissible`: kapatılan uyarılar yeniden doğana kadar gizli kalır.
local dismissed: { [string]: boolean } = {}

local TEXTS: { [string]: { text: string, hint: string, icon: string } } = {
	rulerNotSafe = {
		text = "Your king is exposed",
		hint = "Move it deep into your land.",
		icon = Icons.crown,
	},
	full = {
		text = "A tower is full",
		hint = "Send its units out or set a supply line.",
		icon = Icons.ui.tower,
	},
	overflowing = {
		text = "A tower is overflowing",
		hint = "Units above capacity are being lost.",
		icon = Icons.ui.tower,
	},
	zombies = {
		text = "Zombies are attacking",
		hint = "Leftover units of a fallen player.",
		icon = Icons.ui.warning,
	},
}

local function rows(alerts: Alerts.Alerts): { Row }
	local result: { Row } = {}
	local function add(key: string, towerId: number?, dismissible: boolean)
		if dismissible and dismissed[key] then
			return
		end
		local t = TEXTS[key]
		local row: Row = {
			key = key,
			text = t.text,
			hint = t.hint,
			icon = t.icon,
			towerId = towerId,
			dismissible = dismissible,
		}
		table.insert(result, row)
	end
	if
		not Alerts.has(alerts, Alerts.RulerUnderAttack)
		and Alerts.has(alerts, Alerts.RulerNotSafe)
	then
		add("rulerNotSafe", alerts.rulerPosition, true)
	end
	if alerts.full ~= nil then
		add("full", alerts.full, true)
	end
	if alerts.overflowing ~= nil then
		add("overflowing", alerts.overflowing, true)
	end
	if alerts.zombies ~= nil then
		add("zombies", alerts.zombies, true)
	end
	return result
end

local function missileText(): (string, string)
	local first = missiles[1]
	local soonest = first.seconds
	for _, missile in missiles do
		soonest = math.min(soonest, missile.seconds)
	end
	local title = if #missiles > 1
		then "Missiles incoming!"
		elseif first.unit == Unit.Nuke then "Nuke incoming!"
		else "EMP incoming!"
	return title, string.format("Impact in %ds. Tap to see the target.", soonest)
end

local function missileRow(frame: Frame)
	local first = missiles[1]
	local title, hint = missileText()
	missileTitle = title
	local item = Kit.panel(frame, UDim2.new(1, 0, 0, 68), true, 14)
	item.Name = "missile"
	item.LayoutOrder = 0
	Kit.stroke(item, Theme.colors.alert, 2)
	local button = Instance.new("TextButton")
	button.Name = "Text"
	button.Text = ""
	button.BackgroundTransparency = 1
	button.Size = UDim2.fromScale(1, 1)
	button.Parent = item
	Kit.padding(button, 0, 8, 0, 10)
	Kit.list(button, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })
	Kit.icon(button, Icons.units[first.unit] or Icons.ui.warning, 44, 1)
	local texts = Kit.box(button, UDim2.new(1, -54, 1, 0), 2)
	Kit.list(texts, { alignY = Enum.VerticalAlignment.Center })
	local titleLabel =
		Kit.text(texts, title, "label", Theme.colors.danger, UDim2.new(1, 0, 0, 26), 1)
	titleLabel.TextWrapped = false
	local hintLabel = Kit.text(texts, hint, "small", Theme.colors.text, UDim2.new(1, 0, 0, 22), 2)
	hintLabel.TextWrapped = false
	hintLabel.TextTruncate = Enum.TextTruncate.AtEnd
	missileHint = hintLabel
	button.Activated:Connect(function()
		local panTo = onPanTo
		local target = missiles[1]
		if panTo and target then
			Audio.play("click")
			panTo(target.towerId)
		end
	end)
end

local function render()
	local frame = list
	if frame == nil then
		return
	end
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	missileHint = nil
	if #missiles > 0 then
		missileRow(frame)
	end
	local alerts = current
	if alerts == nil then
		return
	end
	for order, row in rows(alerts) do
		local item = Kit.panel(frame, UDim2.new(1, 0, 0, 68), true, 14)
		item.Name = row.key
		item.LayoutOrder = order
		local button = Instance.new("TextButton")
		button.Name = "Text"
		button.Text = ""
		button.BackgroundTransparency = 1
		button.Size = UDim2.new(1, if row.dismissible then -44 else 0, 1, 0)
		button.Parent = item
		Kit.padding(button, 0, 8, 0, 10)
		Kit.list(button, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })
		Kit.icon(button, row.icon, 44, 1)
		local texts = Kit.box(button, UDim2.new(1, -54, 1, 0), 2)
		Kit.list(texts, { alignY = Enum.VerticalAlignment.Center })
		local title = Kit.text(texts, row.text, "label", nil, UDim2.new(1, 0, 0, 26), 1)
		title.TextWrapped = false
		title.TextTruncate = Enum.TextTruncate.AtEnd
		local hint =
			Kit.text(texts, row.hint, "small", Theme.colors.muted, UDim2.new(1, 0, 0, 22), 2)
		hint.TextWrapped = false
		hint.TextTruncate = Enum.TextTruncate.AtEnd
		local towerId = row.towerId
		if towerId ~= nil then
			button.Activated:Connect(function()
				local panTo = onPanTo
				if panTo then
					Audio.play("click")
					panTo(towerId)
				end
			end)
		end
		if row.dismissible then
			local close = Instance.new("TextButton")
			close.Name = "Dismiss"
			close.AnchorPoint = Vector2.new(1, 0)
			close.Position = UDim2.fromScale(1, 0)
			close.Size = UDim2.new(0, 44, 1, 0)
			close.BackgroundTransparency = 1
			close.TextColor3 = Theme.colors.muted
			close.FontFace = Theme.fonts.heading
			close.TextSize = 26
			close.Text = "×"
			close.Parent = item
			close.Activated:Connect(function()
				dismissed[row.key] = true
				render()
			end)
		end
	end
end

function AlertOverlay.init(panTo: (towerId: number) -> ())
	if list ~= nil then
		return
	end
	onPanTo = panTo
	local frame = Kit.box(Nav.left(), UDim2.fromScale(1, 0), 2)
	frame.Name = "Alerts"
	frame.AutomaticSize = Enum.AutomaticSize.Y
	Kit.list(frame, { gap = 6 })
	list = frame
end

-- `ForceView`: füze listesi. Yapı değişmediyse yalnız süre yazısı güncellenir.
function AlertOverlay.setMissiles(next: { ForceView.Missile })
	local hadMissiles = #missiles > 0
	missiles = next
	if #next == 0 then
		if hadMissiles then
			render()
		end
		return
	end
	local title, hint = missileText()
	local label = missileHint
	if label ~= nil and title == missileTitle then
		label.Text = hint
	else
		render()
	end
end

-- Boşluk tuşu: en acil uyarının kulesi (füze, kral, dolu, taşan, zombi).
function AlertOverlay.topTower(): number?
	if #missiles > 0 then
		return missiles[1].towerId
	end
	local alerts = current
	if alerts == nil then
		return nil
	end
	return alerts.rulerPosition or alerts.overflowing or alerts.full or alerts.zombies
end

-- Sunucudan yeni uyarılar (`Delta.alerts`, yalnız değişince gelir).
function AlertOverlay.apply(alerts: Alerts.Alerts)
	current = alerts
	render()
end

-- Yeniden doğuş / ölüm: uyarılar ve kapatılanlar sıfırlanır.
function AlertOverlay.reset()
	current = nil
	table.clear(missiles)
	table.clear(dismissed)
	render()
end

return AlertOverlay
