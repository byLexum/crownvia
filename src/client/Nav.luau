--!strict
-- Sağ üst sütun: ekran düğmeleri (hedefler, mağaza, dolap, arkadaşlar, ayarlar) ve altında lider
-- tablosu; sol üst sütun: öğretici kartı ve uyarılar. Ortak sütunlar sayesinde öğeler üst üste
-- binmez: biri görününce diğeri aşağı kayar. Ekranlar `main` tarafından bağlanır.

local GuiService = game:GetService("GuiService")

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)

local Nav = {}

export type Actions = {
	goals: () -> (),
	store: () -> (),
	locker: () -> (),
	friends: () -> (),
	settings: () -> (),
}

local SIZE = 68

local right: Frame? = nil
local left: Frame? = nil
local gui: ScreenGui? = nil

local function ensure()
	if gui ~= nil then
		return
	end
	local screen = Kit.screen("Nav", 20)

	local column = Kit.box(screen, UDim2.fromOffset(0, 0))
	column.Name = "Right"
	column.AnchorPoint = Vector2.new(1, 0)
	column.Position = UDim2.new(1, -10, 0, 6)
	column.AutomaticSize = Enum.AutomaticSize.XY
	Kit.scaled(column)
	Kit.list(column, { gap = 8, alignX = Enum.HorizontalAlignment.Right })
	right = column

	-- Sol: Roblox menü düğmelerinin altı.
	local leftColumn = Kit.box(screen, UDim2.fromOffset(340, 0))
	leftColumn.Name = "Left"
	leftColumn.Position = UDim2.new(0, 10, 0, GuiService.TopbarInset.Height + 8)
	leftColumn.AutomaticSize = Enum.AutomaticSize.Y
	Kit.scaled(leftColumn)
	Kit.list(leftColumn, { gap = 8 })
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(function()
		leftColumn.Position = UDim2.new(0, 10, 0, GuiService.TopbarInset.Height + 8)
	end)
	left = leftColumn

	Kit.mount(screen)
	gui = screen
end

function Nav.setVisible(visible: boolean)
	ensure();
	(gui :: ScreenGui).Enabled = visible
end

function Nav.right(): Frame
	ensure()
	return right :: Frame
end

function Nav.left(): Frame
	ensure()
	return left :: Frame
end

function Nav.init(actions: Actions)
	local row = Kit.box(Nav.right(), UDim2.fromOffset(0, SIZE), 0)
	row.Name = "Buttons"
	row.AutomaticSize = Enum.AutomaticSize.X
	Kit.list(row, { horizontal = true, gap = 6 })
	local specs: { { name: string, icon: string, run: () -> () } } = {
		{ name = "Goals", icon = Icons.ui.goal, run = actions.goals },
		{ name = "Store", icon = Icons.ui.store, run = actions.store },
		{ name = "Locker", icon = Icons.ui.locker, run = actions.locker },
		{ name = "Friends", icon = Icons.ui.friends, run = actions.friends },
		{ name = "Settings", icon = Icons.ui.gear, run = actions.settings },
	}
	for i, spec in specs do
		Kit.iconButton(row, spec.icon, SIZE, spec.run, i, spec.name)
	end
end

return Nav
