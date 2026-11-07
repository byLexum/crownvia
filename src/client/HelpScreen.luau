--!strict
-- Nasıl oynanır: oyunun fikirleri ve kontroller. Metinler bize ait; kurallar kaynak oyunla aynı
-- (`docs/KAYNAK_INCELEMESI.md`). Yeni kural anlatılmaz, yalnız oyunda olan.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local TowerType = require(Sim.TowerType)
local TowerTypeId = require(Sim.TowerTypeId)
local Unit = require(Sim.Unit)

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local HelpScreen = {}

local TOPICS: { { icon: string, title: string, text: string } } = {
	{
		icon = Icons.ui.tower,
		title = "Capture towers",
		text = "Gold numbers can send troops: drag from that tower to a target. Captured towers produce units for you.",
	},
	{
		icon = Icons.crown,
		title = "Protect your king",
		text = "If your king dies, all your towers go unclaimed. Keep it shielded, deep in your land.",
	},
	{
		icon = Icons.ui.trophy,
		title = "How to win",
		text = "Capture more towers and hold them to earn score. Keep your king in a Bunker or Headquarters to survive nukes.",
	},
	{
		icon = Icons.ui.flag,
		title = "Upgrade",
		text = "Tap your tower to upgrade it. Some upgrades need other tower types first.",
	},
	{
		icon = Icons.ui.truck,
		title = "Supply lines",
		text = "Select a tower, then drag to a target. New units go there on their own. Repeat the line to remove it.",
	},
	{
		icon = Icons.ui.radar,
		title = "Fog of war",
		text = "You only see around your towers. Radars see farther.",
	},
	{
		icon = Icons.ui.friends,
		title = "Alliances",
		text = "Tap another player's tower to request an alliance. When both agree, they turn purple.",
	},
}

local MOUSE: { { string } } = {
	{ "Drag tower", "Send troops" },
	{ "Click tower", "Select" },
	{ "Drag map", "Move camera" },
	{ "WASD", "Move camera" },
	{ "Wheel, Q / E", "Zoom" },
	{ "H", "Go to king" },
	{ "Hold T", "Show towers of the selected type" },
	{ "Space", "Go to the most urgent alert" },
	{ "1 - 6", "Jump between soldier, tank, air, artillery, EMP, nuke towers" },
	{ "Shift + 1 - 6", "Select all towers of that type" },
	{ "Shift + click", "Add a tower to the group" },
	{ "Drag group tower", "Send from every tower in the group" },
	{ "X", "Clear selection" },
	{ "Shift + R", "Remove supply lines" },
}

local TOUCH: { { string } } = {
	{ "Drag tower", "Send troops" },
	{ "Tap tower", "Select" },
	{ "Drag map", "Move camera" },
	{ "Pinch", "Zoom" },
	{ "Bottom buttons", "Tap: jump between towers. Hold: select all." },
	{ "Drag group tower", "Send from every tower in the group" },
	{ "Truck button", "Hold to remove supply lines" },
}

local modal: Kit.Modal? = nil

local function topic(parent: Instance, order: number, icon: string, title: string, text: string)
	local card = Kit.well(parent, UDim2.new(), order)
	Kit.padding(card, 12)
	Kit.icon(card, icon, 64).Position = UDim2.fromOffset(0, 4)
	local texts = Kit.box(card, UDim2.new(1, -78, 1, 0))
	texts.Position = UDim2.fromOffset(78, 0)
	Kit.list(texts, { gap = 2 })
	Kit.text(texts, title, "heading", Theme.colors.text, UDim2.new(1, 0, 0, 30), 1).TextSize = 21
	local body = Kit.text(texts, text, "small", Theme.colors.muted, UDim2.new(1, 0, 1, -32), 2)
	body.TextYAlignment = Enum.TextYAlignment.Top
end

local function controls(parent: Instance, order: number, rows: { { string } })
	local card = Kit.well(parent, UDim2.fromScale(1, 0), order)
	card.AutomaticSize = Enum.AutomaticSize.Y
	Kit.padding(card, 14)
	Kit.list(card, { gap = 4 })
	Kit.text(card, Strings.controls, "heading", nil, UDim2.new(1, 0, 0, 34), 0)
	for i, row in rows do
		local line = Kit.box(card, UDim2.new(1, 0, 0, 28), i)
		Kit.text(line, row[1], "label", Theme.colors.gold, UDim2.fromScale(0.36, 1)).TextSize = 18
		local value = Kit.text(line, row[2], "small", Theme.colors.text, UDim2.fromScale(0.64, 1))
		value.Position = UDim2.fromScale(0.36, 0)
	end
end

local function page(parent: Instance): ScrollingFrame
	local s = Kit.scroll(parent, UDim2.new(1, 0, 1, -62), 8)
	s.Position = UDim2.fromOffset(0, 62)
	return s
end

-- Yükseltme ağacı: kök kuleler ve altlarında girintili yükseltmeler.
local function towerRow(parent: Instance, order: number, towerType: number, depth: number)
	local name = TowerTypeId.name(towerType)
	local row = Kit.well(parent, UDim2.new(1, -depth * 34 - 8, 0, 92), order)
	local wrap = Kit.box(parent, UDim2.new(1, 0, 0, 92), order)
	row.Parent = wrap
	row.Position = UDim2.fromOffset(depth * 34, 0)
	Kit.padding(row, 6, 12)
	Kit.list(row, { horizontal = true, gap = 12, alignY = Enum.VerticalAlignment.Center })
	Kit.towerPreview(row, name, 76, 1)
	local lines = Kit.box(row, UDim2.new(1, -92, 1, 0), 2)
	Kit.list(lines, { gap = 2, alignY = Enum.VerticalAlignment.Center })
	Kit.text(lines, name, "label", nil, UDim2.new(1, 0, 0, 26), 1)
	Kit.text(
		lines,
		Strings.towerRoles[name] or "",
		"small",
		Theme.colors.muted,
		UDim2.new(1, 0, 0, 22),
		2
	)
	local needs = {}
	for _, p in TowerType.prerequisites(towerType) do
		table.insert(needs, string.format("%s %d", TowerTypeId.name(p.towerType), p.count))
	end
	if #needs > 0 then
		local text = string.format(Strings.towerNeeds, table.concat(needs, ", "))
		Kit.text(lines, text, "small", Theme.colors.gold, UDim2.new(1, 0, 0, 22), 3)
	end
end

local function buildTowers(parent: Instance): ScrollingFrame
	local s = page(parent)
	local hasParent: { [number]: boolean } = {}
	for towerType = 0, TowerTypeId.COUNT - 1 do
		for _, upgrade in TowerType.upgrades(towerType) do
			hasParent[upgrade] = true
		end
	end
	local order = 0
	local function walk(towerType: number, depth: number)
		order += 1
		towerRow(s, order, towerType, depth)
		for _, upgrade in TowerType.upgrades(towerType) do
			walk(upgrade, depth + 1)
		end
	end
	for towerType = 0, TowerTypeId.COUNT - 1 do
		if not hasParent[towerType] then
			walk(towerType, 0)
		end
	end
	return s
end

local function buildUnits(parent: Instance): ScrollingFrame
	local s = page(parent)
	for _, unit in Unit.all() do
		local name = Unit.name(unit)
		local row = Kit.well(s, UDim2.new(1, -8, 0, 92), unit + 1)
		Kit.padding(row, 6, 12)
		Kit.list(row, { horizontal = true, gap = 12, alignY = Enum.VerticalAlignment.Center })
		Kit.icon(row, Icons.units[unit] or "", 68, 1)
		local lines = Kit.box(row, UDim2.new(1, -84, 1, 0), 2)
		Kit.list(lines, { gap = 2, alignY = Enum.VerticalAlignment.Center })
		Kit.text(lines, name, "label", nil, UDim2.new(1, 0, 0, 26), 1)
		Kit.text(
			lines,
			Strings.unitTexts[name] or "",
			"small",
			Theme.colors.muted,
			UDim2.new(1, 0, 0, 22),
			2
		)
		local facts = { Strings.unitSpeed[Unit.speed(unit, TowerTypeId.Village)] or "" }
		local range = Unit.rangedDistance(unit)
		if range ~= nil then
			table.insert(facts, string.format(Strings.unitRange, range))
		end
		if Unit.canCapture(unit) then
			table.insert(facts, Strings.unitCaptures)
		end
		local built = {}
		for towerType = 0, TowerTypeId.COUNT - 1 do
			if unit ~= Unit.Shield and TowerType.unitGeneration(towerType, unit) ~= nil then
				table.insert(built, TowerTypeId.name(towerType))
			end
		end
		if #built > 0 and #built < 6 then
			table.insert(facts, string.format(Strings.unitBuiltAt, table.concat(built, ", ")))
		end
		Kit.text(
			lines,
			table.concat(facts, "  •  "),
			"small",
			Theme.colors.gold,
			UDim2.new(1, 0, 0, 22),
			3
		)
	end
	return s
end

function HelpScreen.init()
	if modal ~= nil then
		return
	end
	local m = Kit.modal({
		name = "Help",
		title = Strings.howToPlay,
		icon = Icons.ui.help,
		size = Vector2.new(960, 560),
		order = 52,
	})
	-- Kaynak: `towers_dialog.rs`, `units_dialog.rs`. Sekmeler ilk açılışta kurulur (kule önizlemesi
	-- ViewportFrame, 27 tanesi menü açılışını yavaşlatmasın).
	local scroll = Kit.scroll(m.body, UDim2.new(1, 0, 1, -62), 12)
	scroll.Position = UDim2.fromOffset(0, 62)
	local towers: ScrollingFrame? = nil
	local units: ScrollingFrame? = nil
	Kit.tabs(
		m.body,
		{ Strings.helpGuide, Strings.helpTowers, Strings.helpUnits },
		function(index: number)
			if index == 2 and towers == nil then
				towers = buildTowers(m.body)
			elseif index == 3 and units == nil then
				units = buildUnits(m.body)
			end
			scroll.Visible = index == 1
			if towers then
				towers.Visible = index == 2
			end
			if units then
				units.Visible = index == 3
			end
		end
	)

	local grid = Kit.box(scroll, UDim2.fromScale(1, 0), 1)
	grid.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0.5, -6, 0, 118)
	layout.CellPadding = UDim2.fromOffset(12, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	for i, t in TOPICS do
		topic(grid, i, t.icon, t.title, t.text)
	end
	controls(scroll, 2, if UserInputService.TouchEnabled then TOUCH else MOUSE)
	modal = m
end

function HelpScreen.open()
	local m = modal
	if m then
		m.open()
	end
end

return HelpScreen
