--!strict
-- Dolap: sahip olunan kozmetikleri kuşanma (Kiomet'te yok; `docs/HESAP_MAGAZA.md`). Her yuva için
-- varsayılan + katalog ürünleri; sahip olunmayan kilitli görünür ve mağazaya yönlendirir.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Account"):WaitForChild("Catalog"))
local CosmeticArt = require(Shared:WaitForChild("Art"):WaitForChild("CosmeticArt"))
local ProjectileArt = require(Shared:WaitForChild("Art"):WaitForChild("ProjectileArt"))

local AccountView = require(script.Parent.AccountView)
local Audio = require(script.Parent.Audio)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local LockerScreen = {}

local modal: Kit.Modal? = nil
local grid: GuiObject? = nil
local slotIndex = 1
local onStore: ((itemId: string) -> ())? = nil

local render: () -> ()

local function cell(
	parent: Instance,
	order: number,
	image: string?,
	title: string,
	on: boolean,
	locked: boolean,
	run: () -> ()
)
	local c = Instance.new("TextButton")
	c.Name = title
	c.Text = ""
	c.AutoButtonColor = false
	c.BackgroundColor3 = if on then Theme.colors.navy else Theme.colors.well
	c.BorderSizePixel = 0
	c.LayoutOrder = order
	Kit.corner(c, 14)
	if on then
		Kit.stroke(c, Theme.colors.gold, 2)
	end
	c.Parent = parent
	if image then
		local art = Kit.icon(c, image, 140)
		art.AnchorPoint = Vector2.new(0.5, 0)
		art.Position = UDim2.new(0.5, 0, 0, 12)
		art.ImageTransparency = if locked then 0.55 else 0
	end
	if locked then
		local lock = Kit.icon(c, Icons.ui.lock, 38)
		lock.AnchorPoint = Vector2.new(1, 0)
		lock.Position = UDim2.new(1, -8, 0, 8)
	end
	local name = Kit.text(c, title, "label", nil, UDim2.new(1, -12, 0, 30))
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.new(0.5, 0, 1, -34)
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local state = Kit.text(
		c,
		if on then Strings.equippedShort elseif locked then Strings.locked else Strings.owned,
		"small",
		if on then Theme.colors.gold else Theme.colors.muted,
		UDim2.new(1, -12, 0, 26)
	)
	state.AnchorPoint = Vector2.new(0.5, 1)
	state.Position = UDim2.new(0.5, 0, 1, -8)
	state.TextXAlignment = Enum.TextXAlignment.Center
	c.Activated:Connect(function()
		Audio.play("click")
		run()
	end)
end

render = function()
	local frame = grid
	if frame == nil then
		return
	end
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local profile = AccountView.profile()
	if profile == nil then
		return
	end
	local slot = Catalog.SLOTS[slotIndex]
	local equipped = profile.equipped[slot]
	cell(
		frame,
		0,
		if slot == "crown"
			then Icons.crown
			elseif slot == "capture" then ProjectileArt.fx.ring
			else Icons.ui.trophy,
		Strings.standard,
		equipped == nil,
		false,
		function()
			AccountView.equip(slot, nil)
		end
	)
	for _, item in Catalog.all() do
		if item.slot == slot then
			local owned = AccountView.owns(item)
			cell(
				frame,
				item.order,
				CosmeticArt.previews[item.id],
				Strings.itemNames[item.id] or item.id,
				equipped == item.id,
				not owned,
				function()
					if owned then
						AccountView.equip(slot, if equipped == item.id then nil else item.id)
					else
						local m = modal
						local store = onStore
						if m and store then
							m.close()
							store(item.id)
						end
					end
				end
			)
		end
	end
end

function LockerScreen.init(store: (itemId: string) -> ())
	if modal ~= nil then
		return
	end
	onStore = store
	local m = Kit.modal({
		name = "Locker",
		title = Strings.lockerTitle,
		icon = Icons.ui.locker,
		size = Vector2.new(900, 520),
	})
	local names = {}
	for _, slot in Catalog.SLOTS do
		table.insert(names, Strings.slotNames[slot] or slot)
	end
	Kit.tabs(m.body, names, function(index: number)
		slotIndex = index
		render()
	end)
	local scroll = Kit.scroll(m.body, UDim2.new(1, 0, 1, -64))
	scroll.Position = UDim2.fromOffset(0, 64)
	local layout = scroll:FindFirstChildOfClass("UIListLayout")
	if layout then
		layout:Destroy()
	end
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0.25, -9, 0, 236)
	gridLayout.CellPadding = UDim2.fromOffset(10, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = scroll
	grid = scroll
	modal = m
	AccountView.onProfileChanged(render)
	render()
end

function LockerScreen.open()
	local m = modal
	if m then
		render()
		m.open()
	end
end

return LockerScreen
