--!strict
-- Kule canlılığı: yalnız görsel, kural yok. Kule modelleri tek parça (çanak/baca ayrı değil),
-- bu yüzden hareket parçacıkla verilir:
--   - sanayi kuleleri (Factory, Refinery, Reactor, Centrifuge, Armory): tepeden yavaş duman,
--   - algılayıcı kuleler (Radar, Ews, Satellite): yerde genişleyen soluk tarama halkası.
-- Yalnız sahipli ve aktif (d = 0) kulede çalışır; sahipsiz ya da yükseltmedeki kule sönük kalır.
-- Kural etkisi yok: görüş yarıçapı halkanın boyutuyla gösterilmez (yalnız süs).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProjectileArt = require(Shared:WaitForChild("Art"):WaitForChild("ProjectileArt"))
local TowerTypeId = require(Shared:WaitForChild("Sim"):WaitForChild("TowerTypeId"))

local TowerIdle = {}

local FX = ProjectileArt.fx

local SMOKE: { [number]: boolean } = {
	[TowerTypeId.Factory] = true,
	[TowerTypeId.Refinery] = true,
	[TowerTypeId.Reactor] = true,
	[TowerTypeId.Centrifuge] = true,
	[TowerTypeId.Armory] = true,
}

local SWEEP: { [number]: boolean } = {
	[TowerTypeId.Radar] = true,
	[TowerTypeId.Ews] = true,
	[TowerTypeId.Satellite] = true,
}

-- Baca: modelin en yüksek noktası (tek parça modelde baca ayrı değil). Kule tipi başına bir kez,
-- yukarıdan ızgara ışınıyla bulunur ve parça boyutuna oranla saklanır. 2026-11-06: duman kulenin
-- ortasından çıkıyordu (Fabrika bacası merkezden ~1,4 stud kenarda; Studio ölçümü).
local chimneys: { [number]: Vector3 } = {}

local function chimneyOffset(part: BasePart, towerType: number): Vector3
	local cached = chimneys[towerType]
	if cached then
		return cached * part.Size
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { part }
	local cf = part.CFrame
	local size = part.Size
	local best: Vector3? = nil
	local N = 16
	for i = 0, N do
		for j = 0, N do
			local localXZ = Vector3.new((i / N - 0.5) * size.X, size.Y, (j / N - 0.5) * size.Z)
			local origin = cf:PointToWorldSpace(localXZ)
			local hit = workspace:Raycast(origin, cf.UpVector * -size.Y * 2, params)
			if hit then
				local localHit = cf:PointToObjectSpace(hit.Position)
				if best == nil or localHit.Y > best.Y then
					best = localHit
				end
			end
		end
	end
	-- Işın tutmadıysa (parça henüz dünyada değil / sorgulanamıyor): tepe ortası, önbelleğe alma.
	if best == nil then
		return Vector3.new(0, size.Y / 2, 0)
	end
	local found = best :: Vector3
	chimneys[towerType] = found / size
	return found
end

local function smoke(part: BasePart, towerType: number): ParticleEmitter
	local a = Instance.new("Attachment")
	a.Name = "IdleSmoke"
	a.Position = chimneyOffset(part, towerType) + Vector3.new(0, 0.2, 0)
	a.Parent = part
	local e = Instance.new("ParticleEmitter")
	e.Texture = FX.smoke
	e.Color = ColorSequence.new(Color3.fromRGB(205, 205, 200), Color3.fromRGB(165, 168, 170))
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 2.6),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(3, 4.5)
	e.Rate = 1.6
	e.Speed = NumberRange.new(0.8, 1.3)
	e.SpreadAngle = Vector2.new(12, 12)
	e.EmissionDirection = Enum.NormalId.Top
	e.Acceleration = Vector3.new(0.4, 0.2, 0)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-20, 20)
	e.LightInfluence = 0.8
	e.Parent = a
	return e
end

local function sweep(part: BasePart): ParticleEmitter
	local a = Instance.new("Attachment")
	a.Name = "IdleSweep"
	-- Yer seviyesinde (kule merkezi parça ortası): halkalar ve bölge tülünün üstünde.
	a.Position = Vector3.new(0, -part.Size.Y / 2 + 0.35, 0)
	a.Parent = part
	local e = Instance.new("ParticleEmitter")
	e.Texture = FX.ring
	e.Color = ColorSequence.new(Color3.fromRGB(150, 230, 210))
	e.Size = NumberSequence.new(3, 26)
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(2.4)
	e.Rate = 0.35
	-- Yere paralel kart: yukarı çok yavaş hız + hıza dik yönelim.
	e.Speed = NumberRange.new(0.01)
	e.EmissionDirection = Enum.NormalId.Top
	e.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
	e.LightEmission = 0.6
	e.LightInfluence = 0
	e.Parent = a
	return e
end

-- Kule gövdesi her kurulduğunda ve durum değiştiğinde çağrılır.
function TowerIdle.apply(part: BasePart, towerType: number, owner: number, delay: number)
	local live = owner ~= 0 and delay <= 0
	if SMOKE[towerType] then
		local a = part:FindFirstChild("IdleSmoke")
		local e = if a then a:FindFirstChildOfClass("ParticleEmitter") else smoke(part, towerType)
		if e then
			e.Enabled = live
		end
	end
	if SWEEP[towerType] then
		local a = part:FindFirstChild("IdleSweep")
		local e = if a then a:FindFirstChildOfClass("ParticleEmitter") else sweep(part)
		if e then
			e.Enabled = live
		end
	end
end

return TowerIdle
