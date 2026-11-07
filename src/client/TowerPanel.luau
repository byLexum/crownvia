--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/ui/tower_overlay.rs

-- Seçili kule paneli. Kaynaktaki `TowerOverlay`:
--   - kule tipi, yükseltme sürüyorsa ilerleme,
--   - üretilen ya da kulede olan birimler: sayı/kapasite,
--   - kendi aktif kulende: yükseltmeler (ön koşullar sayı/gereken) ve `basis`'e geri düşürme,
--   - başka oyuncunun kulesinde: oyuncu adı + ittifak iste / isteği iptal et / ittifakı boz.
-- Kaynaktaki kilit (rank < 3 ve reklam) Roblox'ta yok: rank sapması gereği tüm yükseltmeler açık.
-- Sürükleme sırasında gizlenir (kaynak: "Don't obstruct drag").
-- Telefonda da birlik sayıları okunsun diye sayılar kalın ve ikonun yanında; yükseltmeler kayar.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local TowerType = require(Sim.TowerType)
local TowerTypeId = require(Sim.TowerTypeId)
local Unit = require(Sim.Unit)
local Units = require(Sim.Units)

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

export type Commands = {
	upgrade: (towerId: number, towerType: number) -> (),
	alliance: (with: number, breakAlliance: boolean) -> (),
}

local TowerPanel = {}

local holder: Frame? = nil
local list: Frame? = nil
local commandsRef: Commands? = nil
local shownSignature = ""
-- Yapı değişmeden güncellenen metinler (sayılar, ilerleme). Panel her sayı değişiminde yeniden
-- kurulursa tıklama sırasında düğme silinir ve tıklama kaybolur.
local dynamicTexts: { { label: TextLabel, text: () -> string } } = {}

-- Kayıttaki birimleri `Units` nesnesine çevir (kapasite hesabı kral kalkan bonusunu içerir).
local function unitsOf(record: WorldView.TowerRecord): Units.Units
	local units = Units.new()
	for unit = 0, Unit.COUNT - 1 do
		local count = record.u[unit + 1]
		if count > 0 then
			Units.add(units, unit, count)
		end
	end
	return units
end

local function upgradeList(towerType: number): { { towerType: number, downgrade: boolean } }
	local result = {}
	for _, upgrade in TowerType.upgrades(towerType) do
		table.insert(result, { towerType = upgrade, downgrade = false })
	end
	local basis = TowerType.basis(towerType)
	if basis ~= towerType then
		table.insert(result, { towerType = basis, downgrade = true })
	end
	return result
end

local function prerequisitesText(towerType: number, counts: { [number]: number }): string
	local parts = {}
	for _, p in TowerType.prerequisites(towerType) do
		table.insert(
			parts,
			string.format(
				"%s %d/%d",
				TowerTypeId.name(p.towerType),
				counts[p.towerType] or 0,
				p.count
			)
		)
	end
	return table.concat(parts, ", ")
end

-- Panelin yapısının imzası (hangi satır ve düğmeler var): değişmediyse yeniden kurulmaz,
-- yalnız metinler güncellenir.
local function signature(id: number?, hidden: boolean): string
	if id == nil or hidden then
		return ""
	end
	local record = WorldView.record(id)
	if record == nil then
		return ""
	end
	local parts = { tostring(id), tostring(record.t), tostring(record.o), tostring(record.d > 0) }
	for unit = 0, Unit.COUNT - 1 do
		if record.u[unit + 1] > 0 or TowerType.unitGeneration(record.t, unit) ~= nil then
			table.insert(parts, tostring(unit))
		end
	end
	if record.o == WorldView.me() then
		local counts = WorldView.towerCounts()
		for t = 0, TowerTypeId.COUNT - 1 do
			table.insert(parts, tostring(counts[t] or 0))
		end
	elseif record.o ~= 0 then
		local outgoing, incoming = WorldView.allianceState(record.o)
		table.insert(parts, tostring(outgoing) .. tostring(incoming))
		table.insert(parts, WorldView.playerLabel(record.o))
	end
	return table.concat(parts, "|")
end

local PANEL_WIDTH = 330
-- Yükseltme satırı ve görünen en fazla satır: panel telefonda ekranı kaplamasın.
local UPGRADE_ROW = 72
local UPGRADE_ROWS = 3

local function upgradeRow(
	parent: Instance,
	order: number,
	towerType: number,
	downgrade: boolean,
	enabled: boolean,
	needs: string?,
	run: () -> ()
)
	local row = Kit.well(parent, UDim2.new(1, -8, 0, UPGRADE_ROW - 6), order)
	row.Name = (if downgrade then "Downgrade_" else "Upgrade_") .. TowerTypeId.name(towerType)
	Kit.padding(row, 0, 6, 0, 4)
	Kit.towerPreview(row, TowerTypeId.name(towerType), 56).Position = UDim2.fromOffset(0, 5)
	local texts = Kit.box(row, UDim2.new(1, -170, 1, 0))
	texts.Position = UDim2.fromOffset(60, 0)
	Kit.list(texts, { alignY = Enum.VerticalAlignment.Center })
	local name =
		Kit.text(texts, TowerTypeId.name(towerType), "label", nil, UDim2.new(1, 0, 0, 24), 1)
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	if needs then
		local hint = Kit.text(texts, needs, "small", Theme.colors.muted, UDim2.new(1, 0, 0, 20), 2)
		hint.TextWrapped = false
		hint.TextTruncate = Enum.TextTruncate.AtEnd
	end
	local b = Kit.button(row, {
		variant = if downgrade then "navy" else "gold",
		text = if downgrade then "Revert" else "Upgrade",
		textSize = 15,
		size = UDim2.fromOffset(100, 54),
		enabled = enabled,
		onClick = run,
	})
	b.root.AnchorPoint = Vector2.new(1, 0.5)
	b.root.Position = UDim2.fromScale(1, 0.5)
end

local function build(id: number)
	local frame = list :: Frame
	local commands = commandsRef :: Commands
	local record = WorldView.record(id) :: WorldView.TowerRecord
	local me = WorldView.me()
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	-- Güncel kayıt (kule görüşten çıkarsa son bilinen).
	local function current(): WorldView.TowerRecord
		return WorldView.record(id) or record
	end
	local function dynamic(l: TextLabel, text: () -> string)
		l.Text = text()
		table.insert(dynamicTexts, { label = l, text = text })
	end

	local header = Kit.box(frame, UDim2.new(1, 0, 0, 68), nextOrder())
	Kit.towerPreview(header, TowerTypeId.name(record.t), 68)
	local titles = Kit.box(header, UDim2.new(1, -76, 1, 0))
	titles.Position = UDim2.fromOffset(76, 0)
	Kit.list(titles, { alignY = Enum.VerticalAlignment.Center })
	local title = Kit.text(titles, "", "heading", nil, UDim2.new(1, 0, 0, 30), 1)
	title.TextWrapped = false
	title.TextTruncate = Enum.TextTruncate.AtEnd
	dynamic(title, function(): string
		return TowerTypeId.name(current().t)
	end)
	local status = Kit.text(titles, "", "small", Theme.colors.muted, UDim2.new(1, 0, 0, 22), 2)
	status.TextWrapped = false
	status.TextTruncate = Enum.TextTruncate.AtEnd
	dynamic(status, function(): string
		local r = current()
		if r.d > 0 then
			-- Kaynak (tower_overlay.rs) yalnız `1 - delay / tower_type.delay()` ilerlemesini gösterir.
			-- `delay` hem yükseltmede hem EMP'de kurulur; sebep bilinmediği için "yükseltiliyor"
			-- denmez, nötr "devre dışı" yazılır.
			local total = TowerType.delay(r.t)
			local progress = if total > 0 then math.clamp(1 - r.d / total, 0, 1) else 1
			return string.format("Inactive %d%%", math.floor(progress * 100))
		end
		if r.o == me then
			return "Your tower"
		elseif r.o == 0 then
			return "Unclaimed"
		end
		return WorldView.playerLabel(r.o)
	end)

	-- Kule ne işe yarar: bir cümle (bizim metnimiz, değerler kaynaktan).
	local role = Kit.text(
		frame,
		Strings.towerRoles[TowerTypeId.name(record.t)] or "",
		"small",
		Theme.colors.text,
		UDim2.fromScale(1, 0),
		nextOrder()
	)
	role.AutomaticSize = Enum.AutomaticSize.Y

	-- `units.iter_with_zeros().filter(|(unit, count)| unit_generation(unit).is_some() || count > 0)`
	local grid = Kit.box(frame, UDim2.fromScale(1, 0), nextOrder())
	grid.AutomaticSize = Enum.AutomaticSize.Y
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.5, -4, 0, 46)
	gridLayout.CellPadding = UDim2.fromOffset(6, 6)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	for unit = 0, Unit.COUNT - 1 do
		if record.u[unit + 1] > 0 or TowerType.unitGeneration(record.t, unit) ~= nil then
			local cell = Kit.well(grid, UDim2.new(), unit, 10)
			Kit.padding(cell, 0, 8, 0, 6)
			Kit.list(cell, { horizontal = true, gap = 6, alignY = Enum.VerticalAlignment.Center })
			Kit.icon(cell, Icons.units[unit] or "", 36, 1)
			local count = Kit.text(cell, "", "heading", nil, UDim2.new(1, -42, 1, 0), 2)
			count.TextSize = 22
			count.TextWrapped = false
			dynamic(count, function(): string
				local r = current()
				local capacity = Units.capacity(unitsOf(r), unit, r.t)
				return string.format("%d/%d", r.u[unit + 1], capacity)
			end)
		end
	end

	if record.o == me and record.d == 0 then
		local counts = WorldView.towerCounts()
		local entries = upgradeList(record.t)
		if #entries > 0 then
			local height = math.min(#entries, UPGRADE_ROWS) * UPGRADE_ROW + 6
			local scroll = Kit.scroll(frame, UDim2.new(1, 0, 0, height), 6)
			scroll.LayoutOrder = nextOrder()
			for i, entry in entries do
				local upgradable = TowerType.hasPrerequisites(entry.towerType, counts)
				local needs: string? = nil
				if
					not entry.downgrade
					and next(TowerType.prerequisites(entry.towerType)) ~= nil
				then
					needs = "Needs " .. prerequisitesText(entry.towerType, counts)
				end
				local towerType = entry.towerType
				upgradeRow(scroll, i, towerType, entry.downgrade, upgradable, needs, function()
					commands.upgrade(id, towerType)
				end)
			end
		end
	elseif record.o ~= 0 and record.o ~= me then
		local owner = record.o
		local outgoing, incoming = WorldView.allianceState(owner)
		-- Kaynak: `break_alliance = outgoing_alliance`; mor (karşılıklı) ise "boz", değilse "iptal".
		local text = if outgoing
			then (if incoming then "Break alliance" else "Cancel request")
			else (if incoming then "Accept alliance" else "Request alliance")
		Kit.button(frame, {
			variant = if incoming and not outgoing then "gold" else "navy",
			text = text,
			textSize = 19,
			size = UDim2.new(1, 0, 0, 62),
			order = nextOrder(),
			name = "Alliance",
			onClick = function()
				commands.alliance(owner, outgoing)
			end,
		})
	end
end

function TowerPanel.init(commands: Commands)
	if holder ~= nil then
		return
	end
	commandsRef = commands
	local screen = Kit.screen("TowerPanel", 12)

	-- Sol alt; kamera düğmeleri sağ altta. `Active`: panele tıklama haritaya geçmesin.
	local panel = Kit.panel(screen, UDim2.fromOffset(PANEL_WIDTH, 0), true)
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 10, 1, -10)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Visible = false
	Kit.scaled(panel)
	Kit.padding(panel, 10)
	Kit.list(panel, { gap = 8 })

	Kit.mount(screen)
	holder = panel
	list = panel
end

-- Her kare çağrılır; yalnız gösterilen veri değişince yeniden kurulur.
function TowerPanel.update(hidden: boolean)
	local frame = list
	if frame == nil then
		return
	end
	local id = WorldView.selected()
	local sig = signature(id, hidden)
	if sig == shownSignature then
		for _, entry in dynamicTexts do
			local text = entry.text()
			if entry.label.Text ~= text then
				entry.label.Text = text
			end
		end
		return
	end
	shownSignature = sig
	table.clear(dynamicTexts)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	(holder :: Frame).Visible = sig ~= ""
	if sig ~= "" and id ~= nil then
		build(id)
	end
end

return TowerPanel
