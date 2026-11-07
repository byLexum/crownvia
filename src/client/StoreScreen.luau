--!strict
-- Mağaza (Kiomet'te yok; `docs/HESAP_MAGAZA.md`). Yalnız kozmetik: güç, kasa ve şans satılmaz.
--   - Cosmetics: solda ürün listesi, sağda büyük önizleme + açıklama + eylem,
--   - Credits: Robux paketleri. Kimliği 0 olan Robux ürünü "Soon" (henüz Creator Hub'da yok).
-- Tüm kararları sunucu verir; ekran yalnız istek gönderir, sonucu profil mesajıyla görür.
-- Renk: Credits ile alım altın, Robux ile alım yeşil.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Account"):WaitForChild("Catalog"))
local Products = require(Shared:WaitForChild("Account"):WaitForChild("Products"))
local Rewards = require(Shared:WaitForChild("Account"):WaitForChild("Rewards"))
local CosmeticArt = require(Shared:WaitForChild("Art"):WaitForChild("CosmeticArt"))

local AccountView = require(script.Parent.AccountView)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local StoreScreen = {}

local modal: Kit.Modal? = nil
local creditsLabel: TextLabel? = nil
local listFrame: ScrollingFrame? = nil
local detailFrame: Frame? = nil
local cosmeticsPage: Frame? = nil
local creditsPage: Frame? = nil
local selected = "bronze_seal"
local tabs: Kit.Tabs? = nil

local render: () -> ()

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function priceText(item: Catalog.Item): (string, string?)
	if item.price then
		return tostring(item.price), Icons.ui.coin
	elseif item.pass then
		local pass = Products.pass(item.pass)
		return if pass then Kit.ROBUX .. " " .. pass.robux else "", nil
	end
	return Strings.freeUnlock, nil
end

local function listRow(parent: Instance, order: number, item: Catalog.Item)
	local on = selected == item.id
	local row = Instance.new("TextButton")
	row.Name = item.id
	row.Text = ""
	row.AutoButtonColor = false
	row.BackgroundColor3 = if on then Theme.colors.navy else Theme.colors.well
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, -10, 0, 76)
	row.LayoutOrder = order
	Kit.corner(row, 12)
	if on then
		Kit.stroke(row, Theme.colors.gold, 2)
	end
	row.Parent = parent
	Kit.icon(row, CosmeticArt.previews[item.id] or "", 60).Position = UDim2.fromOffset(8, 8)
	local name =
		Kit.text(row, Strings.itemNames[item.id] or item.id, "label", nil, UDim2.new(1, -80, 0, 28))
	name.Position = UDim2.fromOffset(76, 10)
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local owned = AccountView.owns(item)
	local price, icon = priceText(item)
	local tag = Kit.box(row, UDim2.new(1, -80, 0, 26))
	tag.Position = UDim2.fromOffset(76, 40)
	Kit.list(tag, { horizontal = true, gap = 5, alignY = Enum.VerticalAlignment.Center })
	if owned then
		Kit.text(tag, Strings.owned, "small", Theme.colors.green, UDim2.fromScale(1, 1), 2)
	else
		if icon then
			Kit.icon(tag, icon, 22, 1)
		end
		local value = Kit.text(tag, price, "small", Theme.colors.gold, UDim2.new(1, -28, 1, 0), 2)
		value.FontFace = Theme.fonts.strong
	end
	row.Activated:Connect(function()
		selected = item.id
		AccountView.shopStep(2)
		render()
	end)
end

local function detail(parent: Frame, item: Catalog.Item, profile: AccountView.Profile?)
	clear(parent)
	local stage = Kit.well(parent, UDim2.new(1, 0, 0, 186), 1, 16)
	stage.BackgroundColor3 = Color3.new(1, 1, 1)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Theme.colors.panelRaised, Theme.colors.well)
	gradient.Rotation = 90
	gradient.Parent = stage
	local art = Kit.icon(stage, CosmeticArt.previews[item.id] or "", 168)
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.5)
	if item.slot == "crown" then
		-- Haritadaki gibi: mavi sayı rozetinin üstünde taç.
		local mock = Kit.box(stage, UDim2.fromOffset(92, 120))
		mock.AnchorPoint = Vector2.new(1, 0.5)
		mock.Position = UDim2.new(1, -18, 0.5, 0)
		Kit.icon(mock, CosmeticArt.images[item.id] or "", 46).Position = UDim2.fromOffset(23, 8)
		local pill = Instance.new("TextLabel")
		pill.BackgroundColor3 = Theme.colors.own
		pill.BorderSizePixel = 0
		pill.FontFace = Theme.fonts.heading
		pill.Text = "20"
		pill.TextColor3 = Color3.new(1, 1, 1)
		pill.TextSize = 20
		pill.Position = UDim2.fromOffset(20, 54)
		pill.Size = UDim2.fromOffset(52, 28)
		Kit.corner(pill, 14)
		pill.Parent = mock
		local note =
			Kit.text(mock, Strings.onTheMap, "small", Theme.colors.muted, UDim2.new(1, 0, 0, 24))
		note.Position = UDim2.fromOffset(0, 88)
		note.TextXAlignment = Enum.TextXAlignment.Center
		note.TextSize = 14
	end

	Kit.text(parent, Strings.itemNames[item.id] or item.id, "title", nil, nil, 2).Size =
		UDim2.new(1, 0, 0, 38)
	Kit.paragraph(parent, Strings.slotHints[item.slot] or "", "small", Theme.colors.muted).LayoutOrder =
		3

	local owned = AccountView.owns(item)
	local equipped = profile ~= nil and profile.equipped[item.slot] == item.id
	local options: Kit.ButtonOptions = {
		variant = "navy",
		text = Strings.storeLoading,
		size = UDim2.new(1, 0, 0, 72),
		order = 5,
		name = "Action",
		textSize = 22,
		enabled = false,
	}
	if profile == nil then
		options.text = Strings.storeLoading
	elseif equipped then
		options.text = Strings.unequip
		options.enabled = true
		options.onClick = function()
			AccountView.equip(item.slot, nil)
		end
	elseif owned then
		options.text = Strings.equip
		options.variant = "gold"
		options.enabled = true
		options.onClick = function()
			AccountView.equip(item.slot, item.id)
		end
	elseif item.price then
		local price = item.price
		options.text = string.format(Strings.buyFor, price)
		options.icon = Icons.ui.coin
		options.iconSize = 34
		options.variant = "gold"
		options.enabled = profile.credits >= price
		if not options.enabled then
			options.text = string.format(Strings.needCredits, price - profile.credits)
		end
		options.onClick = function()
			AccountView.shopStep(3)
			AccountView.buy(item.id)
		end
	elseif item.pass then
		local key = item.pass
		local pass = Products.pass(key)
		local available = pass ~= nil and pass.passId ~= 0
		options.text = if pass and available then Kit.ROBUX .. " " .. pass.robux else Strings.soon
		options.variant = "green"
		options.enabled = available
		options.onClick = function()
			AccountView.shopStep(3)
			AccountView.promptPass(key)
		end
	else
		options.text = if item.id == Rewards.PLAY_ITEM
			then string.format(Strings.unlockPlay, profile.activeMinutes, Rewards.PLAY_ITEM_MINUTES)
			else string.format(Strings.unlockAt, profile.captures, profile.frameCaptures)
	end
	Kit.button(parent, options)
end

local function packCard(parent: Instance, order: number, count: number, pack: Products.CreditPack)
	local card = Kit.well(parent, UDim2.new(1 / count, -8, 1, 0), order, 16)
	Kit.padding(card, 14)
	Kit.list(card, { gap = 8, alignX = Enum.HorizontalAlignment.Center })
	if pack.once then
		Kit.stroke(card, Theme.colors.gold, 2)
	end
	Kit.icon(card, CosmeticArt.creditPacks[pack.key] or "", if count > 3 then 150 else 180, 1)
	local amount = Kit.text(card, tostring(pack.credits), "title", Theme.colors.gold, nil, 2)
	amount.TextXAlignment = Enum.TextXAlignment.Center
	amount.Size = UDim2.new(1, 0, 0, 38)
	local caption = if pack.once then Strings.starterPack else Strings.creditPacks
	local label = Kit.text(card, caption, "small", Theme.colors.muted, nil, 3)
	label.TextXAlignment = Enum.TextXAlignment.Center
	if pack.once then
		local note = Kit.text(card, Strings.oneTime, "small", Theme.colors.gold, nil, 4)
		note.TextXAlignment = Enum.TextXAlignment.Center
	end
	local available = pack.productId ~= 0
	local key = pack.key
	Kit.button(card, {
		variant = "green",
		text = if available then Kit.ROBUX .. " " .. pack.robux else Strings.soon,
		size = UDim2.new(1, 0, 0, 68),
		order = 5,
		textSize = 22,
		enabled = available,
		onClick = function()
			AccountView.shopStep(3)
			AccountView.promptCreditPack(key)
		end,
	})
end

local function renderPacks(profile: AccountView.Profile?)
	local page = creditsPage
	if page == nil then
		return
	end
	clear(page)
	local visible: { Products.CreditPack } = {}
	for _, pack in Products.CREDIT_PACKS do
		-- Tek seferlik paket: ürün açılmadıysa ya da alındıysa görünmez.
		local bought = profile ~= nil and profile.oncePacks[pack.key] == true
		if not pack.once or (pack.productId ~= 0 and not bought) then
			table.insert(visible, pack)
		end
	end
	for i, pack in visible do
		packCard(page, i, #visible, pack)
	end
end

render = function()
	local list = listFrame
	local right = detailFrame
	if list == nil or right == nil then
		return
	end
	local profile = AccountView.profile()
	if creditsLabel then
		creditsLabel.Text = if profile then tostring(profile.credits) else "..."
	end
	clear(list)
	local order = 0
	for _, slot in Catalog.SLOTS do
		order += 1
		local head =
			Kit.text(list, Strings.slotNames[slot] or slot, "small", Theme.colors.muted, nil, order)
		head.FontFace = Theme.fonts.strong
		for _, item in Catalog.all() do
			if item.slot == slot then
				order += 1
				listRow(list, order, item)
			end
		end
	end
	local item = Catalog.get(selected)
	if item then
		detail(right, item, profile)
	end
	renderPacks(profile)
end

function StoreScreen.init()
	if modal ~= nil then
		return
	end
	local m = Kit.modal({
		name = "Store",
		title = Strings.storeTitle,
		icon = Icons.ui.store,
		size = Vector2.new(980, 580),
	})
	local pill, label = Kit.pill(m.panel, Icons.ui.coin, "0", Theme.colors.gold, 46)
	pill.AnchorPoint = Vector2.new(1, 0)
	pill.Position = UDim2.new(1, -74, 0, 13)
	creditsLabel = label

	tabs = Kit.tabs(m.body, { Strings.cosmetics, Strings.creditPacks }, function(index: number)
		(cosmeticsPage :: Frame).Visible = index == 1
		(creditsPage :: Frame).Visible = index == 2
		if index == 2 then
			AccountView.shopStep(2)
		end
	end, 0)

	local page = Kit.box(m.body, UDim2.new(1, 0, 1, -64))
	page.Position = UDim2.fromOffset(0, 64)
	cosmeticsPage = page
	local scroll = Kit.scroll(page, UDim2.new(0, 400, 1, 0), 6)
	listFrame = scroll
	local right = Kit.box(page, UDim2.new(1, -416, 1, 0))
	right.Position = UDim2.fromOffset(416, 0)
	Kit.list(right, { gap = 6 })
	detailFrame = right

	local packs = Kit.box(m.body, UDim2.new(1, 0, 1, -64))
	packs.Position = UDim2.fromOffset(0, 64)
	packs.Visible = false
	Kit.list(packs, { horizontal = true, gap = 12 })
	creditsPage = packs

	modal = m
	AccountView.onProfileChanged(render)
	render()
end

-- `itemId` verilirse Cosmetics sekmesinde o ürün seçili açılır (dolaptaki kilitli ürün).
function StoreScreen.open(itemId: string?)
	local m = modal
	if m == nil then
		return
	end
	if itemId then
		selected = itemId
		local bar = tabs
		if bar then
			bar.select(1)
		end
		(cosmeticsPage :: Frame).Visible = true
		(creditsPage :: Frame).Visible = false
	end
	render()
	m.open()
	AccountView.shopStep(1)
	if itemId then
		AccountView.shopStep(2)
		task.defer(function()
			local list = listFrame
			local row = list and list:FindFirstChild(itemId)
			if list and row and row:IsA("GuiObject") then
				local offset = row.AbsolutePosition.Y
					- list.AbsolutePosition.Y
					+ list.CanvasPosition.Y
				list.CanvasPosition = Vector2.new(0, math.max(0, offset - 40))
			end
		end)
	end
end

return StoreScreen
