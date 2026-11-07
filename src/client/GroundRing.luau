--!strict
-- Yerdeki halka: seçim, grup, hedef, yükseltme, füze uyarısı. Opak ince parçalardan örülür: saydam
-- yüzeyler (Decal, Beam) bölge tülüyle parça merkezine göre sıralanıyor, halkanın yarısı tülün
-- altında kalıyor ve kamera oynadıkça titriyordu. Opak halka derinlik sınamasıyla tülün üstünde
-- kalır. Düz Beam şerit kıvrıldığı, SurfaceGui çizilmediği için kullanılamadı. Yalnız görsel.

local TweenService = game:GetService("TweenService")

local GroundRing = {}

-- Yerdeki ok şeritleri (Beam) için kamera yönünde kaydırma (stud): tülün önünde kalır.
GroundRing.Z_OFFSET = 1

local SEGMENTS = 24
local THICKNESS = 0.55
local HEIGHT = 0.06
-- Bu saydamlığın üstü gizli sayılır: opak halkanın ara saydamlığı yok.
local HIDE_ABOVE = 0.7

export type Ring = {
	setCFrame: (cframe: CFrame) -> (),
	setColor: (color: Color3) -> (),
	setTransparency: (transparency: number) -> (),
	setDiameter: (diameter: number) -> (),
	-- Çap `from`..`to` arasında sürekli gidip gelir.
	pulse: (from: number, to: number, seconds: number) -> (),
	destroy: () -> (),
}

function GroundRing.new(name: string, diameter: number, color: Color3, parent: Instance): Ring
	local holder = Instance.new("Folder")
	holder.Name = name
	local parts: { BasePart } = {}
	for i = 1, SEGMENTS do
		local segment = Instance.new("Part")
		segment.Name = "Segment"
		segment.Anchored = true
		segment.CanCollide = false
		segment.CanQuery = false
		segment.CanTouch = false
		segment.CastShadow = false
		segment.Material = Enum.Material.SmoothPlastic
		segment.Color = color
		segment.Parent = holder
		parts[i] = segment
	end

	local origin = CFrame.new()
	local size = diameter

	local function layout()
		local radius = size / 2
		local length = math.pi * size / SEGMENTS * 1.08
		local targets = table.create(SEGMENTS)
		for i, segment in parts do
			segment.Size = Vector3.new(THICKNESS, HEIGHT, length)
			local angle = (i - 1) / SEGMENTS * math.pi * 2
			targets[i] = origin * CFrame.Angles(0, angle, 0) * CFrame.new(radius, 0, 0)
		end
		workspace:BulkMoveTo(parts, targets, Enum.BulkMoveMode.FireCFrameChanged)
	end
	layout()
	holder.Parent = parent

	local driver: NumberValue? = nil
	local tween: Tween? = nil

	return {
		setCFrame = function(cframe: CFrame)
			origin = cframe
			layout()
		end,
		setColor = function(value: Color3)
			for _, segment in parts do
				segment.Color = value
			end
		end,
		setTransparency = function(value: number)
			local hidden = if value > HIDE_ABOVE then 1 else 0
			for _, segment in parts do
				segment.Transparency = hidden
			end
		end,
		setDiameter = function(value: number)
			size = value
			layout()
		end,
		pulse = function(from: number, to: number, seconds: number)
			local number = Instance.new("NumberValue")
			number.Value = from
			number.Changed:Connect(function(value: number)
				size = value
				layout()
			end)
			driver = number
			local t = TweenService:Create(
				number,
				TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Value = to }
			)
			tween = t
			t:Play()
		end,
		destroy = function()
			if tween then
				tween:Cancel()
			end
			if driver then
				driver:Destroy()
			end
			holder:Destroy()
		end,
	}
end

return GroundRing
