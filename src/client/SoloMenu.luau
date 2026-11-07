--!strict
-- Play Solo: tek pencere, sekmeyle zorluk seçimi, START. Seçilen zorluk kendi parti sunucusunu açar
-- (kodiak "Play with friends" sunucusu, davetsiz). Kurallar aynı; yalnız bot sayısı ve
-- `bot_aggression` değişir. Değerler `PartyRules.DIFFICULTIES`; bekleme ve hata ekranı `PartyMenu`.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PartyRules = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Party"):WaitForChild("PartyRules")
)

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local PartyMenu = require(script.Parent.PartyMenu)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local SoloMenu = {}

type Option = { id: string, title: string, hint: string, icon: string }

local OPTIONS: { Option } = {
	{
		id = "relaxed",
		title = Strings.difficultyRelaxed,
		hint = Strings.difficultyRelaxedHint,
		icon = Icons.ui.rankOne,
	},
	{
		id = "standard",
		title = Strings.difficultyStandard,
		hint = Strings.difficultyStandardHint,
		icon = Icons.ui.rankTwo,
	},
	{
		id = "brutal",
		title = Strings.difficultyBrutal,
		hint = Strings.difficultyBrutalHint,
		icon = Icons.ui.rankThree,
	},
}
local DEFAULT_OPTION = 2

local modal: Kit.Modal? = nil

local function build(): Kit.Modal
	local m = Kit.modal({
		name = "SoloMenu",
		title = Strings.soloTitle,
		size = Vector2.new(560, 380),
		order = 52,
	})
	Kit.list(m.body, { gap = 12 })

	local selected = OPTIONS[DEFAULT_OPTION]
	local info = Kit.well(m.body, UDim2.new(1, 0, 0, 118), 2)
	info.Name = "Info"
	Kit.padding(info, 10, 14)
	Kit.list(info, { horizontal = true, gap = 14, alignY = Enum.VerticalAlignment.Center })
	local badge = Kit.icon(info, selected.icon, 96, 1)
	local lines = Kit.box(info, UDim2.new(1, -110, 1, 0), 2)
	Kit.list(lines, { gap = 4, alignY = Enum.VerticalAlignment.Center })
	local bots = Kit.text(lines, "", "heading", Theme.colors.gold, UDim2.new(1, 0, 0, 30), 1)
	local hint = Kit.text(lines, "", "body", Theme.colors.muted, UDim2.new(1, 0, 0, 52), 2)

	local function show(option: Option)
		selected = option
		badge.Image = option.icon
		bots.Text = string.format(Strings.soloBots, PartyRules.DIFFICULTIES[option.id].bots)
		hint.Text = option.hint
	end

	local names = {}
	for _, option in OPTIONS do
		table.insert(names, option.title)
	end
	local tabs = Kit.tabs(m.body, names, function(index: number)
		show(OPTIONS[index])
	end, 1)
	tabs.select(DEFAULT_OPTION)
	show(selected)

	Kit.button(m.body, {
		variant = "gold",
		text = Strings.difficultyStart,
		textSize = 24,
		size = UDim2.new(1, 0, 0, 72),
		order = 3,
		name = "Start",
		onClick = function()
			m.close()
			PartyMenu.startSolo(selected.id)
		end,
	})
	return m
end

function SoloMenu.open()
	local m: Kit.Modal = modal or build()
	modal = m
	m.open()
end

return SoloMenu
