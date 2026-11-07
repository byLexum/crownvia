--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/game.rs (kamera, klavye), server/src/service.rs (bounding_rectangle)
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: client/src/io/pan_zoom.rs (tag 0.1.1)

-- RTS kamera. kodiak `PanZoom` → bizde `center`/`zoom` durumu; Kiomet `game.rs` klavye ve
-- tekerlek davranışı. Koordinatlar dünya biriminde (Rust x, y; y kuzey). Roblox'ta y → -Z.
-- `zoom`: görünümün yatay yarı genişliği (dünya birimi), kodiak `get_zooms().x`.
-- Kodiak 2B ortografik kamera kullanır; Roblox'ta perspektif kamera, bakılan noktadaki yatay
-- yarı genişlik `zoom` olacak şekilde uzaklık hesaplanır.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local TowerId = require(Sim.TowerId)
local TowerType = require(Sim.TowerType)

local WorldView = require(script.Parent.WorldView)

local shakeAmount = 0

local Camera = {}

-- Bakış eğimi (eski sabit kamera ile aynı: 140 yukarı, 40 güney).
-- Bakış: yataydan ~50° (hedef görünüm B, minyatür masa hissi).
local VIEW_OFFSET = Vector3.new(0, 100, 84).Unit

-- Tutup sürükleme: `anchor` dünya noktası ekranda `screen` altında kalacak şekilde kaydırılır.
-- Olay başına değil, kare başına uygulanır (aynı karede birden çok olay kamerayı aşırı kaydırmasın).
type Grab = { anchor: Vector2, screen: Vector2 }

type State = {
	grab: Grab?,
	center: Vector2,
	zoom: number,
	bottomLeft: Vector2,
	topRight: Vector2,
	ready: boolean,
	wasAlive: boolean,
}

local state: State = {
	grab = nil,
	center = Vector2.zero,
	zoom = 1,
	bottomLeft = Vector2.new(-1, -1),
	topRight = Vector2.new(1, 1),
	ready = false,
	wasAlive = false,
}

-- Menü arkası canlı dünya: girdi yok, kamera izlenen botun toprağında yavaşça süzülür.
local MENU_DRIFT_RADIUS = 0.35
local MENU_DRIFT_SPEED = 0.05
local MENU_FOLLOW = 0.4
local menuMode = false

function Camera.setMenu(enabled: boolean)
	menuMode = enabled
end

-- `PanZoom::min_zoom` (debug değil)
local function minZoom(): number
	return 10
end

-- `PanZoom::max_zoom`
local function maxZoom(): number
	local span = state.topRight - state.bottomLeft
	return math.max(span.X, span.Y) * 0.75
end

local function aspectRatio(): number
	local size = workspace.CurrentCamera.ViewportSize
	if size.Y <= 0 then
		return 1
	end
	return size.X / size.Y
end

-- `PanZoom::get_zooms`
local function zooms(): Vector2
	return Vector2.new(state.zoom, state.zoom / aspectRatio())
end

-- `PanZoom::clamp_center`
local function clampCenter()
	local min, max = state.bottomLeft, state.topRight
	local x = if min.X > max.X
		then (min.X + max.X) * 0.5
		else math.clamp(state.center.X, min.X, max.X)
	local y = if min.Y > max.Y
		then (min.Y + max.Y) * 0.5
		else math.clamp(state.center.Y, min.Y, max.Y)
	state.center = Vector2.new(x, y)
end

-- `PanZoom::reset_center`
-- Kameranın gördüğü dünya genişliği (kaynaktaki `zoom`).
function Camera.zoom(): number
	return state.zoom
end

function Camera.resetCenter()
	state.center = (state.bottomLeft + state.topRight) * 0.5
end

-- `PanZoom::reset_zoom`: ortadaki yakınlık.
function Camera.resetZoom()
	-- Varsayılan: modeller okunacak kadar yakın (görsel tercih; sınırlar kaynakla aynı).
	state.zoom = minZoom() + (maxZoom() - minZoom()) * 0.3
end

-- `PanZoom::multiply_zoom`: `origin` (dünya) ekranda yerinde kalır.
function Camera.multiplyZoom(origin: Vector2, factor: number)
	if factor ~= factor or factor == math.huge or factor == -math.huge then
		return
	end
	local relative = (origin - state.center) / state.zoom
	state.zoom = math.clamp(state.zoom * factor, minZoom(), math.max(minZoom(), maxZoom()))
	state.center = origin - relative * state.zoom
	clampCenter()
end

-- `PanZoom::pan`: dünya birimi cinsinden imleç hareketi.
function Camera.pan(delta: Vector2)
	state.center -= delta
	clampCenter()
end

-- `PanZoom::pan_to`
function Camera.panTo(target: Vector2)
	state.center = target
	clampCenter()
end

-- `PanZoom::set_bounds`
local function setBounds(bottomLeft: Vector2, topRight: Vector2)
	state.bottomLeft = bottomLeft
	state.topRight = topRight
	local c = state.center
	local inside = c.X >= bottomLeft.X
		and c.X <= topRight.X
		and c.Y >= bottomLeft.Y
		and c.Y <= topRight.Y
	if not state.ready or not inside or state.zoom < minZoom() then
		Camera.resetCenter()
		Camera.resetZoom()
		state.ready = true
	end
end

-- `TowerService::get_game_update` `bounding_rectangle`: kendi kulelerinin sınır kutusu + kenar payı
-- (aktif kule tiplerinin en büyük `sensor_radius / CONVERSION` değeri, 3..12). Sunucu bunu
-- gönderiyordu; bizde istemci kendi kulelerinden hesaplar (kendi kulelerini her zaman görür).
-- Kulesi yoksa dünya merkezindeki chunk.
local function boundingRectangle(): (Vector2, Vector2)
	local me = WorldView.me()
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local margin = 0
	for id, record in WorldView.records() do
		if record.o == me then
			local x, y = TowerId.x(id), TowerId.y(id)
			minX, minY = math.min(minX, x), math.min(minY, y)
			maxX, maxY = math.max(maxX, x), math.max(maxY, y)
			if record.d == 0 then
				margin = math.max(margin, TowerType.sensorRadius(record.t) // TowerId.CONVERSION)
			end
		end
	end
	local conversion = TowerId.CONVERSION
	if minX == math.huge then
		-- `World::CENTER` chunk'ı (16×16 kule).
		local chunk = 16
		local cx = TowerId.x(TowerId.CENTER) // chunk * chunk
		local cy = TowerId.y(TowerId.CENTER) // chunk * chunk
		return Vector2.new(cx, cy) * conversion, Vector2.new(cx + chunk, cy + chunk) * conversion
	end
	margin = math.clamp(margin, 3, 12)
	minX, minY = math.max(minX - margin, 0), math.max(minY - margin, 0)
	maxX, maxY = maxX + margin, maxY + margin
	-- `floor_position` / `ceil_position`
	return Vector2.new(minX, minY) * conversion, Vector2.new(maxX + 1, maxY + 1) * conversion
end

-- Dünya (x, y) → Roblox konumu (y = 0 düzlemi).
local function toWorld3(point: Vector2): Vector3
	local s = WorldView.STUDS_PER_UNIT
	return Vector3.new(point.X * s, 0, -point.Y * s)
end

-- Ekran noktasının dünya koordinatı (yer düzlemi). `InputObject.Position` ile aynı uzay.
function Camera.screenToWorld(screen: Vector2): Vector2?
	local camera = workspace.CurrentCamera
	local ray = camera:ScreenPointToRay(screen.X, screen.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = -ray.Origin.Y / ray.Direction.Y
	if t < 0 then
		return nil
	end
	local hit = ray.Origin + ray.Direction * t
	local s = WorldView.STUDS_PER_UNIT
	return Vector2.new(hit.X / s, -hit.Z / s)
end

-- Kaydırmayı başlat: ekran noktasının altındaki dünya noktası tutulur. nil → bırak.
function Camera.grab(screen: Vector2?)
	if screen == nil then
		state.grab = nil
		return
	end
	local anchor = Camera.screenToWorld(screen)
	state.grab = if anchor then { anchor = anchor, screen = screen } else nil
end

-- Tutulan noktayı yeni ekran konumuna taşı (kare sonunda uygulanır).
function Camera.moveGrab(screen: Vector2)
	local grab = state.grab
	if grab ~= nil then
		grab.screen = screen
	end
end

-- Tutulan dünya noktası (çimdik yakınlaştırmasının merkezi).
function Camera.grabAnchor(): Vector2?
	local grab = state.grab
	return if grab then grab.anchor else nil
end

-- Fare tekerleği / çimdik: kodiak `raw_zoom(delta)` → `multiply_zoom(imleç, 2^(delta/3))`.
function Camera.rawZoom(screen: Vector2, delta: number)
	local origin = Camera.screenToWorld(screen) or state.center
	Camera.multiplyZoom(origin, 2 ^ (delta * (1 / 3)))
end

local function keyDown(...: Enum.KeyCode): boolean
	if UserInputService:GetFocusedTextBox() ~= nil then
		return false
	end
	for _, key in { ... } do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

-- Kral kulesine dön (`Key::H`, `alerts.ruler_position`).
function Camera.panToRuler()
	local ruler = WorldView.myRulerTower()
	if ruler ~= nil then
		local x, y = TowerId.integerPosition(ruler)
		Camera.panTo(Vector2.new(x, y))
	end
end

-- Her kare: sınırlar, klavye (game.rs), kamera konumu.
function Camera.update(dt: number, alive: boolean)
	local bottomLeft, topRight = boundingRectangle()
	setBounds(bottomLeft, topRight)

	if alive then
		if not state.wasAlive then
			Camera.resetCenter()
			Camera.resetZoom()
		end

		local pan = Vector2.zero
		if keyDown(Enum.KeyCode.Left, Enum.KeyCode.A) then
			pan += Vector2.new(1, 0)
		end
		if keyDown(Enum.KeyCode.Right, Enum.KeyCode.D) then
			pan -= Vector2.new(1, 0)
		end
		if keyDown(Enum.KeyCode.Down, Enum.KeyCode.S) then
			pan += Vector2.new(0, 1)
		end
		if keyDown(Enum.KeyCode.Up, Enum.KeyCode.W) then
			pan -= Vector2.new(0, 1)
		end
		local z = zooms()
		Camera.pan(pan * dt * math.max(z.X, z.Y) * 1.5)

		if keyDown(Enum.KeyCode.H) then
			Camera.panToRuler()
		end

		local factor = 1
		if keyDown(Enum.KeyCode.Q) then
			factor -= math.min(dt * 2.5, 1)
		end
		if keyDown(Enum.KeyCode.E) then
			factor += math.min(dt * 2.5, 1)
		end
		if factor ~= 1 then
			Camera.multiplyZoom(state.center, factor)
		end
	elseif menuMode then
		-- Sınır kutusu merkezi çevresinde yavaş Lissajous; hedef değişince sıçramaz.
		local t = os.clock() * MENU_DRIFT_SPEED
		local reach = state.zoom * MENU_DRIFT_RADIUS
		local middle = (state.bottomLeft + state.topRight) * 0.5
		local target = middle + Vector2.new(math.cos(t), math.sin(t * 1.7)) * reach
		state.center = state.center:Lerp(target, math.min(dt * MENU_FOLLOW, 1))
		clampCenter()
		Camera.resetZoom()
	else
		Camera.resetCenter()
		Camera.resetZoom()
	end
	state.wasAlive = alive

	-- Tutup sürükleme (önceki karenin kamerasıyla ölçülür, sonra kamera güncellenir).
	local grab = state.grab
	if grab ~= nil then
		local under = Camera.screenToWorld(grab.screen)
		if under ~= nil then
			Camera.pan(under - grab.anchor)
		end
	end

	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	-- Bakılan noktada yatay yarı genişlik = zoom: d = zoom / tan(yatay FOV / 2).
	local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2) * aspectRatio()
	local distance = state.zoom * WorldView.STUDS_PER_UNIT / math.max(tanHalf, 1e-3)
	local target = toWorld3(state.center)
	local cframe = CFrame.lookAt(target + VIEW_OFFSET * distance, target)
	-- Sarsıntı (yalnız görsel): hızla sönen küçük konum titreşimi.
	if shakeAmount > 0.01 then
		local t = os.clock() * 38
		local k = shakeAmount * distance * 0.004
		cframe += Vector3.new(math.sin(t * 1.3) * k, math.sin(t * 1.7) * k * 0.6, math.cos(t) * k)
		shakeAmount *= math.exp(-dt * 5)
	else
		shakeAmount = 0
	end
	camera.CFrame = cframe
end

-- Kamera sarsıntısı: `strength` 0..1+ (nükleer ~1). Kameranın baktığı noktaya uzaklıkla zayıflar.
function Camera.shake(at: Vector3, strength: number)
	if menuMode then
		return
	end
	local focus = toWorld3(state.center)
	local range = state.zoom * WorldView.STUDS_PER_UNIT * 1.5
	local falloff = math.clamp(
		1
			- (Vector3.new(at.X, 0, at.Z) - Vector3.new(focus.X, 0, focus.Z)).Magnitude
				/ math.max(range, 1),
		0,
		1
	)
	shakeAmount = math.max(shakeAmount, strength * falloff)
end

-- Ödül anı: kameranın baktığı yerde sarsıntı (menzilden bağımsız).
function Camera.kick(strength: number)
	shakeAmount = math.max(shakeAmount, strength)
end

-- Testler/hata ayıklama için.
function Camera.debugState(): (Vector2, number)
	return state.center, state.zoom
end

return Camera
