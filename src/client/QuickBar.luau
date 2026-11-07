--!strict
-- Hızlı seçim çubuğu: sahip olunan üretim kulelerini türe göre gösterir. Dokun / 1-6: o türün
-- kuleleri arasında gez. Basılı tut / Shift + 1-6: türün hepsini grup seç. Kontrol kolaylığı,
-- kural değil: gönderim yine tek tek `DeployForce` (Input.luau). Kaynakta yok. Boş tür gizlidir.

local UserInputService = game:GetService("UserInputService")

local Icons = require(script.Parent.Icons)
local Input = require(script.Parent.Input)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

local QuickBar = {}

local BUTTON = 66
local HOLD_SECS = 0.4
local REFRESH_SECS = 0.5

local gui: ScreenGui? = nil
local cells: { { root: GuiObject, count: TextLabel } } = {}
local timer = 0

local function cell(parent: Frame, index: number, group: Input.Group)
	local button = Kit.iconButton(
		parent,
		Icons.units[group.units[1]] or "",
		BUTTON,
		function() end,
		index,
		group.name
	)
	local root = button.root
	local count = Kit.text(root, "", "label", Theme.colors.gold, UDim2.fromOffset(40, 20))
	count.AnchorPoint = Vector2.new(1, 1)
	count.Position = UDim2.new(1, -5, 1, -4)
	count.TextXAlignment = Enum.TextXAlignment.Right
	count.ZIndex = 5
	if not UserInputService.TouchEnabled then
		local key =
			Kit.text(root, tostring(index), "small", Theme.colors.text, UDim2.fromOffset(20, 18))
		key.Position = UDim2.fromOffset(6, 3)
		key.ZIndex = 5
	end
	-- Basılı tutma: bırakınca değil, süre dolunca grup seçilir.
	local pressedAt: number? = nil
	root.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			local started = os.clock()
			pressedAt = started
			task.delay(HOLD_SECS, function()
				if pressedAt == started then
					pressedAt = nil
					Input.selectGroup(index)
				end
			end)
		end
	end)
	root.InputEnded:Connect(function(input)
		local kind = input.UserInputType
		if
			(kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch)
			and pressedAt
		then
			pressedAt = nil
			Input.cycleGroup(index)
		end
	end)
	cells[index] = { root = root, count = count }
end

function QuickBar.init()
	if gui ~= nil then
		return
	end
	local screen = Kit.screen("QuickBar", 11)
	screen.Enabled = false
	local row = Kit.box(screen, UDim2.fromOffset(0, BUTTON))
	row.Name = "Row"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, -10)
	row.AutomaticSize = Enum.AutomaticSize.X
	Kit.scaled(row)
	Kit.list(row, { horizontal = true, gap = 6 })
	for index, group in Input.GROUPS do
		cell(row, index, group)
	end
	Kit.mount(screen)
	gui = screen
end

function QuickBar.setVisible(visible: boolean)
	local screen = gui
	if screen then
		screen.Enabled = visible
	end
end

function QuickBar.update(dt: number)
	timer += dt
	if timer < REFRESH_SECS then
		return
	end
	timer = 0
	for index, entry in cells do
		local count = #Input.groupTowers(index)
		entry.root.Visible = count > 0
		entry.count.Text = tostring(count)
	end
end

return QuickBar
