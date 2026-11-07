--!strict
-- Sıralama ekranı: günlük, haftalık, tüm zamanlar (kodiak `LeaderboardOverlay` dönemleri). Veri
-- sunucudan (`Rankings`) gelir; ekran açılınca istenir. Geçen haftanın ilk 10'u rozet alır.

local Players = game:GetService("Players")

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local RankingsScreen = {}

type Entry = { name: string, score: number, you: boolean? }

local PERIODS = { "daily", "weekly", "allTime" }

-- İlk üç sıra: madalya ikonu (Icons.ui), sonrası numara.
local MEDALS: { string } = { Icons.ui.rankOne, Icons.ui.rankTwo, Icons.ui.rankThree }

local modal: Kit.Modal? = nil
local list: ScrollingFrame? = nil
local footer: TextLabel? = nil
local data: { [string]: { Entry } } = {}
-- Listede olmayan oyuncunun kendi skoru (sunucu `mine`) ve listelerin sıfırlanmasına kalan süre.
local mine: { [string]: number } = {}
local resets: { [string]: number } = {}
local receivedAt = 0
local period = "weekly"
local send: (message: { [string]: any }) -> () = function(_message: { [string]: any }) end

local function updateFooter()
	local label = footer
	if label == nil then
		return
	end
	local left = resets[period]
	if left == nil then
		label.Text = Strings.rankingsHint
	else
		local remaining = left - (os.clock() - receivedAt)
		label.Text = Strings.rankingsHint
			.. "  "
			.. string.format(Strings.rankingsResets, Kit.duration(remaining))
	end
end

local function addRow(
	frame: ScrollingFrame,
	order: number,
	medal: string?,
	rankText: string,
	name: string,
	score: number,
	you: boolean
)
	local row = Kit.well(frame, UDim2.new(1, -8, 0, 44), order, 10)
	Kit.padding(row, 0, 14, 0, 14)
	Kit.list(row, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })
	if medal then
		Kit.icon(row, medal, 34, 1)
	else
		local rank =
			Kit.text(row, rankText, "label", Theme.colors.muted, UDim2.fromOffset(34, 28), 1)
		rank.TextWrapped = false
		rank.TextXAlignment = Enum.TextXAlignment.Center
	end
	local nameLabel = Kit.text(
		row,
		name,
		"label",
		if you then Theme.colors.gold else nil,
		UDim2.new(1, -140, 0, 28),
		2
	)
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.TextWrapped = false
	local scoreLabel = Kit.text(row, tostring(score), "label", nil, UDim2.fromOffset(84, 28), 3)
	scoreLabel.TextXAlignment = Enum.TextXAlignment.Right
end

local function render()
	updateFooter()
	local frame = list
	if frame == nil then
		return
	end
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local entries: { Entry } = data[period] or {}
	if #entries == 0 then
		local empty = Kit.text(frame, Strings.rankingsEmpty, "body", Theme.colors.muted, nil, 1)
		empty.Size = UDim2.new(1, 0, 0, 60)
		empty.TextXAlignment = Enum.TextXAlignment.Center
		return
	end
	local youListed = false
	for i, entry in entries do
		if entry.you then
			youListed = true
		end
		addRow(
			frame,
			i,
			if i <= 3 then MEDALS[i] else nil,
			tostring(i),
			entry.name,
			entry.score,
			entry.you == true
		)
	end
	-- Ilk 20'de değilse kendi en iyi skorun ayrı satırda.
	local mineScore = mine[period]
	if not youListed and mineScore ~= nil then
		addRow(frame, #entries + 1, nil, "-", Players.LocalPlayer.DisplayName, mineScore, true)
	end
end

local function build(): Kit.Modal
	local m = Kit.modal({
		name = "Rankings",
		title = Strings.rankingsTitle,
		icon = Icons.ui.trophy,
		size = Vector2.new(620, 540),
		order = 53,
	})
	local tabs = Kit.tabs(m.body, {
		Strings.rankingsDaily,
		Strings.rankingsWeekly,
		Strings.rankingsAllTime,
	}, function(index: number)
		period = PERIODS[index]
		render()
	end)
	tabs.select(2)
	local scroll = Kit.scroll(m.body, UDim2.new(1, 0, 1, -116), 6)
	scroll.Position = UDim2.fromOffset(0, 62)
	list = scroll
	-- İki satırlı alt bilgi: rozet ipucu + sıfırlanma süresi.
	local hint = Kit.text(m.body, Strings.rankingsHint, "small", Theme.colors.muted)
	hint.AnchorPoint = Vector2.new(0, 1)
	hint.Position = UDim2.fromScale(0, 1)
	hint.Size = UDim2.new(1, 0, 0, 46)
	hint.TextYAlignment = Enum.TextYAlignment.Bottom
	footer = hint
	return m
end

function RankingsScreen.init(sendMessage: (message: { [string]: any }) -> ())
	send = sendMessage
end

function RankingsScreen.open()
	local m: Kit.Modal = modal or build()
	modal = m
	m.open()
	render()
	send({ kind = "RankingsGet" })
end

-- Sunucu `Rankings`.
function RankingsScreen.apply(message: { [string]: any })
	for _, name in PERIODS do
		if type(message[name]) == "table" then
			data[name] = message[name]
		end
	end
	mine = if type(message.mine) == "table" then message.mine else {}
	resets = if type(message.resets) == "table" then message.resets else {}
	receivedAt = os.clock()
	render()
end

return RankingsScreen
