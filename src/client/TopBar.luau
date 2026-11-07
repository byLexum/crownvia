--!strict
-- Maç içi üst bant ve sağ alt kamera düğmeleri.
--   - üst orta, tek satır: kule sayısı + kral durumu (uyarı bayraklarından: `RulerUnderAttack` →
--     saldırı altında, `RulerNotSafe` → korumasız, yoksa güvende). Saldırıda bant kırmızıya döner;
--     durum yalnız renkle değil ikon ve metinle de okunur. Credits burada yok (mağaza/hedefler).
--   - sağ alt: krala dön (Kiomet `Key::H`), yakınlaştır/uzaklaştır, dokunmatikte hat silme (Shift+R).
-- Yalnız hayattayken görünür.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Alerts =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"):WaitForChild("Alerts"))

local Audio = require(script.Parent.Audio)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Nav = require(script.Parent.Nav)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

local TopBar = {}

export type Actions = {
	panToRuler: () -> (),
	zoom: (factor: number) -> (),
	clearSupplyLines: (held: () -> boolean) -> (),
}

local BAR_HEIGHT = 56
-- Sol üstteki Roblox menü düğmelerinin kapladığı genişlik (piksel) ve sağ düğme sütunuyla boşluk.
local LEFT_RESERVED = 214
local NAV_GAP = 12

local gui: ScreenGui? = nil
local bar: Frame? = nil
local countLabel: TextLabel? = nil
local kingLabel: TextLabel? = nil
local kingIcon: ImageLabel? = nil
local pulse: Tween? = nil
local lastAttacked = false
local timer = 0

local function setBarColor(attacked: boolean)
	local frame = bar
	if frame == nil then
		return
	end
	local gradient = frame:FindFirstChildOfClass("UIGradient") :: UIGradient
	gradient.Color = if attacked
		then ColorSequence.new(Theme.colors.alert, Theme.colors.alertLip)
		else ColorSequence.new(Theme.colors.panelRaised, Theme.colors.panel)
	if pulse then
		pulse:Cancel()
		pulse = nil
	end
	frame.BackgroundTransparency = 0.06
	if attacked then
		local tween = TweenService:Create(
			frame,
			TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.3 }
		)
		tween:Play()
		pulse = tween
	end
end

function TopBar.init(actions: Actions)
	if gui ~= nil then
		return
	end
	local screen = Kit.screen("TopBar", 10)
	screen.Enabled = false

	local frame = Kit.panel(screen, UDim2.fromOffset(0, BAR_HEIGHT), true, 28)
	frame.Name = "Bar"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 6)
	frame.AutomaticSize = Enum.AutomaticSize.X
	Kit.scaled(frame)
	Kit.padding(frame, 0, 22, 0, 12)
	Kit.list(frame, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })

	Kit.icon(frame, Icons.ui.tower, 38, 1)
	local count = Kit.text(frame, "", "heading", nil, UDim2.fromOffset(0, BAR_HEIGHT), 2)
	count.AutomaticSize = Enum.AutomaticSize.X
	count.TextWrapped = false
	local gap = Kit.box(frame, UDim2.fromOffset(2, 28), 3)
	gap.BackgroundColor3 = Theme.colors.stroke
	gap.BackgroundTransparency = 0
	local crown = Kit.icon(frame, Icons.crown, 38, 4)
	local king =
		Kit.text(frame, Strings.kingSafe, "heading", nil, UDim2.fromOffset(0, BAR_HEIGHT), 5)
	king.AutomaticSize = Enum.AutomaticSize.X
	king.TextWrapped = false

	-- Banda dokununca krala git (saldırıda en hızlı yol).
	local tap = Instance.new("TextButton")
	tap.Name = "Tap"
	tap.Text = ""
	tap.BackgroundTransparency = 1
	tap.Size = UDim2.fromScale(1, 1)
	tap.Parent = screen
	tap.AnchorPoint = frame.AnchorPoint
	tap.Position = frame.Position
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		tap.Size = UDim2.fromOffset(frame.AbsoluteSize.X, frame.AbsoluteSize.Y)
	end)

	-- Bant ortada durur, ama sağ üst düğme sütununa (ve sol üstteki Roblox menüsüne) binmez:
	-- sütunun solunda kalacak kadar sola kayar. "King exposed" gibi geniş metinde ve dar
	-- ekranlarda bant düğmelerin altına giriyordu (2026-11-06).
	local nav = Nav.right()
	local function reposition()
		local width = screen.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local half = frame.AbsoluteSize.X / 2
		local low = LEFT_RESERVED + half
		local high = nav.AbsolutePosition.X - screen.AbsolutePosition.X - NAV_GAP - half
		local center = if low > high then high else math.clamp(width / 2, low, high)
		frame.Position = UDim2.new(0, center, 0, 6)
		tap.Position = frame.Position
	end
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(reposition)
	nav:GetPropertyChangedSignal("AbsoluteSize"):Connect(reposition)
	nav:GetPropertyChangedSignal("AbsolutePosition"):Connect(reposition)
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(reposition)
	task.defer(reposition)
	tap.Activated:Connect(function()
		Audio.play("click")
		actions.panToRuler()
	end)

	-- Sağ alt: kamera düğmeleri.
	local corner = Kit.box(screen, UDim2.fromOffset(0, 74))
	corner.Name = "Corner"
	corner.AnchorPoint = Vector2.new(1, 1)
	corner.Position = UDim2.new(1, -10, 1, -10)
	corner.AutomaticSize = Enum.AutomaticSize.X
	Kit.scaled(corner)
	Kit.list(corner, { horizontal = true, gap = 8, alignX = Enum.HorizontalAlignment.Right })

	if UserInputService.TouchEnabled then
		local holding = false
		local clear = Kit.button(corner, {
			variant = "navy",
			size = UDim2.fromOffset(74, 74),
			icon = Icons.ui.truck,
			iconSize = 46,
			order = 0,
			name = "ClearLines",
		})
		clear.root.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				holding = true
				actions.clearSupplyLines(function()
					return holding
				end)
			end
		end)
		clear.root.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				holding = false
			end
		end)
	end
	Kit.button(corner, {
		variant = "navy",
		text = Strings.toKing,
		icon = Icons.crown,
		iconSize = 36,
		size = UDim2.fromOffset(186, 74),
		textSize = 19,
		order = 1,
		name = "King",
		onClick = actions.panToRuler,
	})
	local zoomButtons: { { text: string, factor: number } } = {
		{ text = "+", factor = 0.7 },
		{ text = "−", factor = 1 / 0.7 },
	}
	for i, spec in zoomButtons do
		Kit.button(corner, {
			variant = "navy",
			text = spec.text,
			textSize = 32,
			size = UDim2.fromOffset(74, 74),
			order = 1 + i,
			name = "Zoom" .. i,
			onClick = function()
				actions.zoom(spec.factor)
			end,
		})
	end

	Kit.mount(screen)
	gui = screen
	bar = frame
	countLabel = count
	kingLabel = king
	kingIcon = crown
end

-- Uyarılar değişince (Delta `alerts`).
function TopBar.applyAlerts(alerts: Alerts.Alerts)
	local label = kingLabel
	local icon = kingIcon
	if label == nil or icon == nil then
		return
	end
	local attacked = Alerts.has(alerts, Alerts.RulerUnderAttack)
	if attacked then
		label.Text = Strings.kingAttacked
		label.TextColor3 = Theme.colors.text
		icon.Image = Icons.ui.warning
	elseif Alerts.has(alerts, Alerts.RulerNotSafe) then
		label.Text = Strings.kingExposed
		label.TextColor3 = Theme.colors.gold
		icon.Image = Icons.crown
	else
		label.Text = Strings.kingSafe
		label.TextColor3 = Theme.colors.text
		icon.Image = Icons.crown
	end
	if attacked ~= lastAttacked then
		setBarColor(attacked)
		-- Uyarı sesi yalnız saldırı başladığında.
		if attacked then
			Audio.play("warning")
		end
	end
	lastAttacked = attacked
end

function TopBar.update(dt: number)
	timer += dt
	if timer < 0.5 or countLabel == nil then
		return
	end
	timer = 0
	local me = WorldView.me()
	local count = 0
	for _, record in WorldView.records() do
		if record.o == me then
			count += 1
		end
	end
	(countLabel :: TextLabel).Text =
		string.format("%d %s", count, if count == 1 then Strings.tower else Strings.towers)
end

function TopBar.setVisible(visible: boolean)
	if gui then
		gui.Enabled = visible
	end
	if not visible then
		lastAttacked = false
		setBarColor(false)
	end
end

return TopBar
