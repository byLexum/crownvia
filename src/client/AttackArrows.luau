--!strict
-- Ekran dışından bana gelen görünür düşman birlikleri için kenar okları. Kaynakta yok, yalnız
-- gösterim: istemcinin zaten gördüğü birliklerden hesaplanır, görüş dışı bilgi kullanmaz. Oka
-- dokununca kamera birliğin hedefine gider.

local ForceView = require(script.Parent.ForceView)
local Input = require(script.Parent.Input)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

local AttackArrows = {}

local MAX_ARROWS = 4
local ARROW_SIZE = 46
local EDGE_MARGIN = 70
local REFRESH_SECS = 0.2

type Arrow = { button: ImageButton, target: number? }

local screen: ScreenGui? = nil
local arrows: { Arrow } = {}
local timer = 0

function AttackArrows.init(panTo: (towerId: number) -> ())
	if screen ~= nil then
		return
	end
	local gui = Kit.screen("AttackArrows", 9, true)
	for i = 1, MAX_ARROWS do
		local button = Instance.new("ImageButton")
		button.Name = "Arrow" .. i
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Size = UDim2.fromOffset(ARROW_SIZE, ARROW_SIZE)
		button.BackgroundTransparency = 1
		button.Image = Input.ASSETS[1]
		button.ImageColor3 = Theme.colors.alert
		button.Visible = false
		button.Parent = gui
		local arrow: Arrow = { button = button, target = nil }
		button.Activated:Connect(function()
			if arrow.target ~= nil then
				panTo(arrow.target)
			end
		end)
		arrows[i] = arrow
	end
	Kit.mount(gui)
	screen = gui
end

function AttackArrows.setVisible(visible: boolean)
	local gui = screen
	if gui then
		gui.Enabled = visible
	end
end

function AttackArrows.update(dt: number)
	timer += dt
	if timer < REFRESH_SECS then
		return
	end
	timer = 0
	local camera = workspace.CurrentCamera
	local viewport = camera.ViewportSize
	local center = viewport / 2
	local used = 0
	local me = WorldView.me()
	if me ~= nil then
		for _, attacker in ForceView.attackers() do
			if used >= MAX_ARROWS then
				break
			end
			local point, onScreen = camera:WorldToViewportPoint(attacker.position)
			if not onScreen then
				local direction = Vector2.new(point.X, point.Y) - center
				if point.Z < 0 then
					direction = -direction
				end
				if direction.Magnitude > 1 then
					local half = center - Vector2.new(EDGE_MARGIN, EDGE_MARGIN)
					local scale = math.min(
						half.X / math.max(math.abs(direction.X), 1e-3),
						half.Y / math.max(math.abs(direction.Y), 1e-3)
					)
					local at = center + direction * scale
					used += 1
					local arrow = arrows[used]
					arrow.target = attacker.towerId
					arrow.button.Position = UDim2.fromOffset(at.X, at.Y)
					-- Doku yukarı bakar; ok birliğin geldiği yönü gösterir.
					arrow.button.Rotation = math.deg(math.atan2(direction.Y, direction.X)) + 90
					arrow.button.Visible = true
				end
			end
		end
	end
	for i = used + 1, MAX_ARROWS do
		arrows[i].button.Visible = false
	end
end

return AttackArrows
