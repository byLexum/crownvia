--!strict
-- Yoldaki birliklerin çizimi: her birlik tek küre + sayı etiketi (CLAUDE.md kural 5:
-- her asker için Part yok). Menzilli birimler (Shell, Emp, Nuke) yay çizen mermi olarak çizilir;
-- varışta yalnız isabet efekti gösterilir, sonucu (hasar, ele geçirme) sunucu verisi gösterir.
-- Simülasyon 4 Hz; konum her karede ara değerle hesaplanır.
-- Kiomet'te karşılığı `Force::interpolated_position` (common/src/force.rs) ve client/src/game.rs.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ProjectileArt = require(Shared:WaitForChild("Art"):WaitForChild("ProjectileArt"))
local UnitArt = require(Shared:WaitForChild("Art"):WaitForChild("UnitArt"))
local Sim = Shared:WaitForChild("Sim")
local Ticks = require(Sim.Ticks)
local Unit = require(Sim.Unit)

local Audio = require(script.Parent.Audio)
local Camera = require(script.Parent.Camera)
local Effects = require(script.Parent.Effects)
local GroundRing = require(script.Parent.GroundRing)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

export type ForceRecord = {
	id: number,
	o: number,
	a: number,
	b: number,
	p: number,
	r: number,
	s: number,
	k: number,
	u: { number },
}

type Extra = { part: Part, offset: CFrame }

type ForceViewEntry = {
	record: ForceRecord,
	part: BasePart,
	extras: { Extra },
	label: TextLabel,
	-- Menzilli birim (Unit.Shell/Emp/Nuke) ya da nil.
	ranged: number?,
	fraction: number,
	-- Gövdenin yerel ileri yönünü uçuş yönüne çeviren dönüş.
	turn: CFrame,
	-- Gövde merkezinin zeminden yüksekliği: kara birimi yola oturur (boyunun yarısı),
	-- hava birimi ve mermi `HEIGHT` + ek yükseklikte uçar.
	lift: number,
	-- Sahip rengiyle boyanan gövde (birlik modeli ya da küre); mermide nil.
	tinted: BasePart?,
}

type RangedStyle = {
	-- Model gelmezse ilkel gövdenin rengi ve parçacık rengi.
	color: Color3,
	-- Yay tepesi, mesafe oranı olarak.
	arc: number,
	-- Uçuş izi: doku, boyut, saniyedeki parçacık.
	trail: string,
	trailSize: number,
	trailRate: number,
}

local ForceView = {}

local COLOR_MINE = Color3.fromRGB(120, 190, 255)
local COLOR_ENEMY = Color3.fromRGB(255, 120, 120)
local COLOR_ZOMBIE = Color3.fromRGB(200, 200, 200)
local HEIGHT = 2.5
-- Yolun üst yüzeyi (WorldView.ROAD_Y) + biraz: birlik yolun üstünde.
local ROAD_TOP = WorldView.ROAD_Y + 0.05

local FX = ProjectileArt.fx

local RANGED_STYLE: { [number]: RangedStyle } = {
	[Unit.Shell] = {
		color = Color3.fromRGB(255, 180, 60),
		arc = 0.22,
		trail = FX.smoke,
		trailSize = 0.6,
		trailRate = 40,
	},
	[Unit.Emp] = {
		color = Color3.fromRGB(90, 230, 255),
		arc = 0.18,
		trail = FX.spark,
		trailSize = 0.8,
		trailRate = 30,
	},
	[Unit.Nuke] = {
		color = Color3.fromRGB(255, 140, 60),
		arc = 0.3,
		trail = FX.fire,
		trailSize = 1.2,
		trailRate = 45,
	},
}

local LAUNCH_SOUND: { [number]: Audio.SoundName } = {
	[Unit.Shell] = "shellFire",
	[Unit.Emp] = "empLaunch",
	[Unit.Nuke] = "nukeLaunch",
}
local IMPACT_SOUND: { [number]: Audio.SoundName } = {
	[Unit.Shell] = "shellImpact",
	[Unit.Emp] = "empImpact",
	[Unit.Nuke] = "nukeImpact",
}

local folder: Folder? = nil
local entries: { [number]: ForceViewEntry } = {}

-- Sunucu tick tahmini (ara değer için).
local lastTick = 0
local lastClock = os.clock()

local function getFolder(): Folder
	if folder == nil then
		local f = Instance.new("Folder")
		f.Name = "Forces"
		f.Parent = WorldView.towersFolder().Parent
		folder = f
	end
	return folder :: Folder
end

local function total(record: ForceRecord): number
	local sum = 0
	for _, count in record.u do
		sum += count
	end
	return sum
end

-- Menzilli birlik tek tip birimden oluşur (Shell, Emp ya da Nuke).
local function rangedUnit(record: ForceRecord): number?
	for unit = Unit.Shell, Unit.Nuke do
		if record.u[unit + 1] > 0 then
			return unit
		end
	end
	return nil
end

local function newPart(
	shape: Enum.PartType,
	size: Vector3,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	return part
end

type EmitterSpec = {
	texture: string,
	color: Color3?,
	size: NumberSequence,
	lifetime: NumberRange,
	speed: NumberRange,
	spread: number?,
	light: number?,
	transparency: NumberSequence?,
	acceleration: Vector3?,
	flat: boolean?,
}

local function emitter(parent: Attachment, spec: EmitterSpec): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = spec.texture
	e.Color = ColorSequence.new(spec.color or Color3.new(1, 1, 1))
	e.Size = spec.size
	e.Lifetime = spec.lifetime
	e.Speed = spec.speed
	e.SpreadAngle = Vector2.new(spec.spread or 180, spec.spread or 180)
	e.LightEmission = spec.light or 0
	e.Transparency = spec.transparency or NumberSequence.new(0, 1)
	e.Acceleration = spec.acceleration or Vector3.zero
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-40, 40)
	if spec.flat then
		-- Yere yatay serilen dalga: hız yukarı, parçacık hıza dik.
		e.Orientation = Enum.ParticleOrientation.VelocityPerpendicular
		e.EmissionDirection = Enum.NormalId.Top
		e.SpreadAngle = Vector2.zero
		e.Rotation = NumberRange.new(0)
		e.RotSpeed = NumberRange.new(0)
	end
	e.Enabled = false
	e.Parent = parent
	return e
end

-- Uçuş izi: mermi kuyruğundan dünyaya bırakılan parçacıklar.
local function addTrail(part: BasePart, tailX: number, style: RangedStyle)
	local tail = Instance.new("Attachment")
	tail.Position = Vector3.new(tailX, 0, 0)
	tail.Parent = part
	local trail = emitter(tail, {
		texture = style.trail,
		size = NumberSequence.new(style.trailSize, style.trailSize * 2),
		lifetime = NumberRange.new(0.4, 0.7),
		speed = NumberRange.new(0.2, 0.6),
		light = 0.6,
		transparency = NumberSequence.new(0.2, 1),
	})
	trail.Rate = style.trailRate
	trail.Enabled = true
end

-- İlkel yedek gövde (model içe aktarılmadıysa): X ekseninde, uçuş yönü +X.
local function primitiveProjectile(unit: number, style: RangedStyle): (BasePart, { Extra }, number)
	local extras: { Extra } = {}
	if unit == Unit.Shell then
		return newPart(
			Enum.PartType.Ball,
			Vector3.new(0.9, 0.9, 0.9),
			style.color,
			Enum.Material.Neon
		),
			extras,
			0.9
	elseif unit == Unit.Emp then
		local tip =
			newPart(Enum.PartType.Ball, Vector3.new(0.8, 0.8, 0.8), style.color, Enum.Material.Neon)
		table.insert(extras, { part = tip, offset = CFrame.new(0.9, 0, 0) })
		return newPart(
			Enum.PartType.Cylinder,
			Vector3.new(1.8, 0.8, 0.8),
			Color3.fromRGB(40, 48, 60),
			Enum.Material.Metal
		),
			extras,
			1.8
	end
	local nose = newPart(
		Enum.PartType.Ball,
		Vector3.new(1, 1, 1),
		Color3.fromRGB(230, 60, 50),
		Enum.Material.Neon
	)
	table.insert(extras, { part = nose, offset = CFrame.new(1.5, 0, 0) })
	return newPart(
		Enum.PartType.Cylinder,
		Vector3.new(3, 1, 1),
		Color3.fromRGB(60, 64, 72),
		Enum.Material.Metal
	),
		extras,
		3
end

-- Mermi gövdesi: içe aktarılmış model (ReplicatedStorage.ProjectileMeshes), yoksa ilkel parçalar.
local function createProjectile(unit: number, style: RangedStyle): (BasePart, { Extra }, CFrame)
	local meshes = ReplicatedStorage:FindFirstChild("ProjectileMeshes")
	local template = if meshes then meshes:FindFirstChild(Unit.name(unit)) else nil
	local root: BasePart
	local extras: { Extra } = {}
	local length: number
	if template and template:IsA("MeshPart") then
		root = template:Clone()
		-- Studio içe aktarıcı modeli X'te ters çevirdi: burun yerel -X.
		addTrail(root, root.Size.X / 2, style)
		return root, extras, CFrame.Angles(0, -math.pi / 2, 0)
	end
	root, extras, length = primitiveProjectile(unit, style)
	addTrail(root, -length / 2, style)
	return root, extras, CFrame.Angles(0, math.pi / 2, 0)
end

-- Baskın birim: kral varsa kral, yoksa en kalabalık hareketli birim (eşitlikte küçük kimlik).
local function dominantUnit(record: ForceRecord): number?
	if record.u[Unit.Ruler + 1] > 0 then
		return Unit.Ruler
	end
	local best, bestCount = nil, 0
	for unit = 0, Unit.COUNT - 1 do
		local count = record.u[unit + 1]
		if count > bestCount and UnitArt.spec[Unit.name(unit)] ~= nil then
			best, bestCount = unit, count
		end
	end
	return best
end

-- Birlik gövdesi: içe aktarılmış model (ReplicatedStorage.UnitMeshes), yoksa küre.
local function createUnitBody(record: ForceRecord): (BasePart, CFrame, number)
	local unit = dominantUnit(record)
	local name = if unit then Unit.name(unit) else ""
	local meshes = ReplicatedStorage:FindFirstChild("UnitMeshes")
	local template = if meshes then meshes:FindFirstChild(name) else nil
	local spec = UnitArt.spec[name]
	local air = spec ~= nil and spec.air
	local body: BasePart
	local turn: CFrame
	if template and template:IsA("MeshPart") then
		-- Studio içe aktarıcı modeli X'te ters çevirdi: ön yerel -X.
		body, turn = template:Clone(), CFrame.Angles(0, -math.pi / 2, 0)
	else
		body =
			newPart(Enum.PartType.Ball, Vector3.new(1.6, 1.6, 1.6), COLOR_MINE, Enum.Material.Neon)
		turn = CFrame.Angles(0, math.pi / 2, 0)
	end
	-- Kara birimi: merkez = yol yüzeyi + boyun yarısı (MeshPart konumu sınır kutusunun merkezi).
	local lift = if air then HEIGHT + 3 else ROAD_TOP + body.Size.Y / 2
	return body, turn, lift
end

local function create(record: ForceRecord): ForceViewEntry
	local ranged = rangedUnit(record)
	local part: BasePart
	local extras: { Extra } = {}
	local turn: CFrame
	local lift = HEIGHT
	local tinted: BasePart? = nil
	if ranged then
		part, extras, turn = createProjectile(ranged, RANGED_STYLE[ranged])
		Audio.worldAt(LAUNCH_SOUND[ranged], WorldView.position(record.a))
	else
		part, turn, lift = createUnitBody(record)
		tinted = part
		-- Kara birliği: arkasında hafif toz (yalnız görsel).
		if lift < HEIGHT then
			local a = Instance.new("Attachment")
			a.Name = "Dust"
			a.Position = Vector3.new(0, -part.Size.Y / 2 + 0.05, 0)
			a.Parent = part
			local dust = Instance.new("ParticleEmitter")
			dust.Texture = ProjectileArt.fx.smoke
			dust.Color = ColorSequence.new(Color3.fromRGB(196, 176, 140))
			dust.Size = NumberSequence.new(0.35, 1.1)
			dust.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.55),
				NumberSequenceKeypoint.new(1, 1),
			})
			dust.Lifetime = NumberRange.new(0.6, 0.9)
			dust.Rate = 6
			dust.Speed = NumberRange.new(0.2, 0.5)
			dust.SpreadAngle = Vector2.new(40, 40)
			dust.LightInfluence = 0.8
			dust.Parent = a
		end
	end
	part.Name = "Force_" .. record.id
	-- İlk karede dünya başlangıcında belirmesin (iz oradan çizilirdi).
	part.Position = WorldView.position(record.a) + Vector3.new(0, lift, 0)
	part.Parent = getFolder()
	for _, extra in extras do
		extra.part.CFrame = part.CFrame * extra.offset
		extra.part.Parent = part
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(4, 2)
	billboard.StudsOffset = Vector3.new(0, 1.8, 0)
	billboard.MaxDistance = 300
	billboard.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.TextScaled = true
	label.FontFace = Theme.fonts.heading
	label.Parent = billboard

	return {
		record = record,
		part = part,
		extras = extras,
		label = label,
		ranged = ranged,
		turn = turn,
		lift = lift,
		tinted = tinted,
		fraction = 0,
	}
end

-- İsabet: parçacık patlaması. Sonuç değil, yalnız isabet anı (hasarı sunucu verisi gösterir).
local function impact(unit: number, at: Vector3)
	Audio.worldAt(IMPACT_SOUND[unit], at)
	Camera.shake(at, if unit == Unit.Nuke then 1.2 elseif unit == Unit.Emp then 0.45 else 0.2)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.Position = at
	holder.Parent = getFolder()
	local origin = Instance.new("Attachment")
	origin.Parent = holder

	local bursts: { { emitter: ParticleEmitter, count: number } } = {}
	local function add(spec: EmitterSpec, count: number)
		table.insert(bursts, { emitter = emitter(origin, spec), count = count })
	end
	if unit == Unit.Shell then
		add({
			texture = FX.fire,
			size = NumberSequence.new(1.5, 3),
			lifetime = NumberRange.new(0.25, 0.4),
			speed = NumberRange.new(2, 5),
			light = 0.8,
		}, 4)
		add({
			texture = FX.smoke,
			size = NumberSequence.new(1.5, 4),
			lifetime = NumberRange.new(0.6, 1),
			speed = NumberRange.new(1, 3),
			acceleration = Vector3.new(0, 2, 0),
		}, 6)
		add({
			texture = FX.spark,
			size = NumberSequence.new(0.6, 0),
			lifetime = NumberRange.new(0.3, 0.5),
			speed = NumberRange.new(8, 14),
			light = 1,
			acceleration = Vector3.new(0, -20, 0),
		}, 10)
	elseif unit == Unit.Emp then
		add({
			texture = FX.ring,
			size = NumberSequence.new(2, 16),
			lifetime = NumberRange.new(0.6),
			speed = NumberRange.new(0.01),
			light = 1,
			transparency = NumberSequence.new(0, 1),
			flat = true,
		}, 1)
		add({
			texture = FX.ring,
			size = NumberSequence.new(1, 8),
			lifetime = NumberRange.new(0.45),
			speed = NumberRange.new(0.01),
			light = 1,
			flat = true,
		}, 1)
		add({
			texture = FX.spark,
			color = Color3.fromRGB(120, 235, 255),
			size = NumberSequence.new(0.8, 0),
			lifetime = NumberRange.new(0.3, 0.6),
			speed = NumberRange.new(6, 12),
			light = 1,
		}, 14)
	else
		add({
			texture = FX.fire,
			size = NumberSequence.new(4, 12),
			lifetime = NumberRange.new(0.5, 0.9),
			speed = NumberRange.new(3, 8),
			light = 0.8,
		}, 14)
		add({
			texture = FX.smoke,
			size = NumberSequence.new(5, 14),
			lifetime = NumberRange.new(1.5, 2.5),
			speed = NumberRange.new(2, 6),
			acceleration = Vector3.new(0, 4, 0),
		}, 18)
		add({
			texture = FX.ring,
			color = Color3.fromRGB(255, 200, 140),
			size = NumberSequence.new(3, 26),
			lifetime = NumberRange.new(0.7),
			speed = NumberRange.new(0.01),
			light = 1,
			flat = true,
		}, 1)
		add({
			texture = FX.spark,
			size = NumberSequence.new(1, 0),
			lifetime = NumberRange.new(0.5, 0.9),
			speed = NumberRange.new(12, 22),
			light = 1,
			acceleration = Vector3.new(0, -25, 0),
		}, 20)
	end
	for _, burst in bursts do
		burst.emitter:Emit(burst.count)
	end
	task.delay(3, function()
		holder:Destroy()
	end)
end

-- Bana gelen Nükleer/EMP: uyarı. Yalnız görünen birliklerden hesaplanır, görüş dışı bilgi yok.
export type Missile = { id: number, unit: number, towerId: number, seconds: number }
local MISSILE_CHECK_SECS = 0.5
local onMissiles: ((missiles: { Missile }) -> ())? = nil
local missileTimer = 0
local warned: { [number]: GroundRing.Ring } = {}

function ForceView.setMissileHandler(handler: (missiles: { Missile }) -> ())
	onMissiles = handler
end

local function clearWarning(id: number)
	local ring = warned[id]
	if ring then
		ring.destroy()
		warned[id] = nil
	end
end

local function warningRing(towerId: number): GroundRing.Ring
	local ring = GroundRing.new("MissileTarget", 15, Theme.colors.alert, getFolder())
	local at = WorldView.position(towerId)
	ring.setCFrame(CFrame.new(at.X, 0.7, at.Z))
	ring.pulse(13, 17, 0.35)
	return ring
end

local function checkMissiles()
	local me = WorldView.me()
	local missiles: { Missile } = {}
	for id, entry in entries do
		local record = entry.record
		local unit = entry.ranged
		local target = WorldView.record(record.b)
		local mine = target ~= nil and target.o == me
		local hostile = record.o ~= me and not WorldView.haveAlliance(record.o, me or 0)
		if (unit == Unit.Nuke or unit == Unit.Emp) and mine and hostile then
			local seconds = (1 - entry.fraction)
				* record.r
				/ math.max(record.s, 1)
				* Ticks.PERIOD_SECS
			table.insert(missiles, {
				id = id,
				unit = unit :: number,
				towerId = record.b,
				seconds = math.ceil(seconds),
			})
			if (warned[id] :: GroundRing.Ring?) == nil then
				warned[id] = warningRing(record.b)
				Audio.world("warning")
			end
		end
	end
	for id in warned do
		local entry = entries[id]
		if entry == nil then
			clearWarning(id)
		end
	end
	local handler = onMissiles
	if handler then
		handler(missiles)
	end
end

-- Kenar okları: bana gelen düşman birlikleri, en yakın varış önce.
export type Attacker = { position: Vector3, towerId: number, remaining: number }

function ForceView.attackers(): { Attacker }
	local me = WorldView.me()
	local list: { Attacker } = {}
	if me == nil then
		return list
	end
	for _, entry in entries do
		local record = entry.record
		local target = WorldView.record(record.b)
		if
			target ~= nil
			and target.o == me
			and record.o ~= me
			and not WorldView.haveAlliance(record.o, me)
		then
			table.insert(list, {
				position = entry.part.Position,
				towerId = record.b,
				remaining = 1 - entry.fraction,
			})
		end
	end
	table.sort(list, function(a, b)
		return a.remaining < b.remaining
	end)
	return list
end

-- Delta'nın tick'i: ara değer saatini günceller.
function ForceView.setServerTick(tick: number)
	lastTick = tick
	lastClock = os.clock()
end

function ForceView.apply(records: { ForceRecord }, removed: { number })
	local me = WorldView.me()
	for _, record in records do
		local entry = entries[record.id]
		if entry == nil then
			entry = create(record)
			entries[record.id] = entry
		end
		local e = entry :: ForceViewEntry
		e.record = record
		if e.tinted then
			e.tinted.Color = if record.o == 0
				then COLOR_ZOMBIE
				elseif record.o == me then COLOR_MINE
				else COLOR_ENEMY
		end
		local count = total(record)
		local text = tostring(count)
		if record.u[Unit.Ruler + 1] > 0 then
			text ..= " K"
		end
		-- Tek mermide sayı yazılmaz.
		e.label.Text = if e.ranged and count == 1 then "" else text
	end
	for _, id in removed do
		local entry = entries[id]
		if entry then
			-- Görüşten çıkan değil, hedefe varan mermi.
			if entry.ranged and entry.fraction >= 0.9 then
				impact(entry.ranged, WorldView.position(entry.record.b) + Vector3.new(0, HEIGHT, 0))
			elseif entry.fraction >= 0.9 then
				-- Düşman kuleye varıp yok olan birlik: çatışma (fetih ise WorldView capture çizer).
				local target = WorldView.record(entry.record.b)
				local owner = entry.record.o
				if owner == me then
					Audio.worldAt("unitLost", WorldView.position(entry.record.b))
				end
				if target and target.o ~= owner and not WorldView.haveAlliance(owner, target.o) then
					Effects.clash(
						WorldView.position(target.id),
						WorldView.recentDrop(target.id),
						getFolder()
					)
				end
			end
			entry.part:Destroy()
			entries[id] = nil
		end
	end
end

function ForceView.clear()
	for id, entry in entries do
		entry.part:Destroy()
		entries[id] = nil
	end
end

local function arcPosition(entry: ForceViewEntry, fraction: number): Vector3
	local record = entry.record
	local from = WorldView.position(record.a)
	local to = WorldView.position(record.b)
	local lift = entry.lift
	if entry.ranged then
		lift += (to - from).Magnitude * RANGED_STYLE[entry.ranged].arc * 4 * fraction * (1 - fraction)
	end
	return from:Lerp(to, fraction) + Vector3.new(0, lift, 0)
end

-- Her karede: `(p + geçen tick × s) / r`, en fazla 1.
function ForceView.render()
	local now = os.clock()
	if now - missileTimer >= MISSILE_CHECK_SECS then
		missileTimer = now
		checkMissiles()
	end
	local elapsedSinceDelta = (os.clock() - lastClock) / Ticks.PERIOD_SECS
	for _, entry in entries do
		local record = entry.record
		-- u16 sarmasına dayanıklı tick farkı
		local ticksSinceSample = ((lastTick - record.k) % 65536) + elapsedSinceDelta
		local fraction =
			math.clamp((record.p + ticksSinceSample * record.s) / math.max(record.r, 1), 0, 1)
		entry.fraction = fraction
		local position = arcPosition(entry, fraction)
		if entry.ranged then
			-- Uçuş yönüne çevir: yerel +X ileri.
			local ahead = arcPosition(entry, math.min(fraction + 0.02, 1))
			if (ahead - position).Magnitude < 1e-3 then
				ahead = position + (WorldView.position(record.b) - WorldView.position(record.a))
			end
			local cframe = CFrame.lookAt(position, ahead) * entry.turn
			entry.part.CFrame = cframe
			for _, extra in entry.extras do
				extra.part.CFrame = cframe * extra.offset
			end
		else
			-- Yol yönüne çevir (birlik yatay gider).
			local road = WorldView.position(record.b) - WorldView.position(record.a)
			-- Canlılık: kara birliği adımla hafif sallanır, hava birliği yavaşça süzülür.
			-- Faz birlik kimliğinden: hepsi aynı anda sallanmasın. Yalnız görsel.
			local t = os.clock() + record.id * 0.37
			if entry.lift < HEIGHT then
				position += Vector3.new(0, math.abs(math.sin(t * 9)) * 0.12, 0)
			else
				position += Vector3.new(0, math.sin(t * 1.6) * 0.35, 0)
			end
			if road.Magnitude > 1e-3 then
				entry.part.CFrame = CFrame.lookAt(position, position + road) * entry.turn
			else
				entry.part.Position = position
			end
		end
	end
end

return ForceView
