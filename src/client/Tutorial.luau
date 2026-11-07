--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/tutorial.rs, client/src/ui/alert_overlay.rs

-- Eğitim. Kiomet'te `Tutorial` durum makinesi → bizde `Tutorial.update`:
--   WaitingToDeploy → Deploying(path) → WaitingToUpgrade → Upgrading(tower) → Done.
--   - `DeployedAnyForce` ve `UpgradedAnyTower` bayrakları ikisi de varsa (sayfa yenilenmiş) atla,
--   - kendi kulelerinin sınır kutusu alanı 18² hücreyi geçince bitir,
--   - `best_deployment`: kral olmayan, ele geçirebilen birimi olan kendi kulesinden, 3 hücre
--     içindeki boş sahipsiz kuleye en iyi yol; puan: −4×uzunluk, hareketli birim üretiyorsa +2,
--     o tipten hiç kulesi yoksa +1 (ilk 50 aday),
--   - `best_upgrade`: ön koşulu tutan yükseltmesi olan aktif kendi kulesi; hareketli birim
--     üreten yükseltme önce.
-- Gösterim: Codex ipucu kartı (sol üst) + hedefte nabız atan halka + kaynaktan hedefe kayan
-- "sürükleme" noktası (kaynaktaki imleç animasyonunun karşılığı). Kart kapatılabilir
-- (`DismissCaptureTutorial` / `DismissUpgradeTutorial`).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local Alerts = require(Sim.Alerts)
local Pathfinding = require(Sim.Pathfinding)
local TowerId = require(Sim.TowerId)
local TowerType = require(Sim.TowerType)
local Unit = require(Sim.Unit)

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Nav = require(script.Parent.Nav)
local Strings = require(script.Parent.Strings)
local GroundRing = require(script.Parent.GroundRing)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

local Tutorial = {}

type State =
	{ kind: "WaitingToDeploy" }
	| { kind: "Deploying", path: { number } }
	| { kind: "WaitingToUpgrade" }
	| { kind: "Upgrading", towerId: number }
	| { kind: "Done" }

local state: State = { kind = "WaitingToDeploy" }
local flags = 0
local alive = false
local timer = 0
local animation = 0

local gui: Frame? = nil
local titleLabel: TextLabel? = nil
local hintLabel: TextLabel? = nil
local stepLabel: TextLabel? = nil
local ring: GroundRing.Ring? = nil
local cursor: Part? = nil

-- Yeniden izlemede eski oyunun bayrakları sayılmaz.
local ignoredFlags = 0
local replaying = false
local isDone: () -> boolean = function()
	return false
end
local onDone: () -> () = function() end
local reported = false

local function hasFlag(flag: number): boolean
	return bit32.band(bit32.band(flags, bit32.bnot(ignoredFlags)), flag) ~= 0
end

local function totalUnits(record: WorldView.TowerRecord): number
	local total = 0
	for _, count in record.u do
		total += count
	end
	return total
end

local function filterSrc(record: WorldView.TowerRecord, me: number?): boolean
	if record.o ~= me or record.u[Unit.Ruler + 1] > 0 then
		return false
	end
	for unit = 0, Unit.COUNT - 1 do
		if record.u[unit + 1] > 0 and Unit.canCapture(unit) then
			return true
		end
	end
	return false
end

local function filterDst(record: WorldView.TowerRecord?): boolean
	return record ~= nil and record.o == 0 and totalUnits(record) == 0
end

local function findPath(src: number, dst: number, me: number): { number }?
	return Pathfinding.findBestPath(
		WorldView.pathView(),
		src,
		dst,
		nil,
		me,
		function(id: number): boolean
			if id == src then
				return true
			end
			local record = WorldView.record(id)
			return record ~= nil and (record.o == me or filterDst(record))
		end
	)
end

local function bestDeployment(me: number): { number }?
	local counts = WorldView.towerCounts()
	local best: { number }? = nil
	local bestScore = -math.huge
	local candidates = 0
	for srcId, src in WorldView.records() do
		if filterSrc(src, me) then
			local x, y = TowerId.x(srcId), TowerId.y(srcId)
			for dx = -3, 3 do
				for dy = -3, 3 do
					local nx, ny = x + dx, y + dy
					if
						candidates < 50
						and nx >= 0
						and ny >= 0
						and nx < TowerId.WORLD_SIZE
						and ny < TowerId.WORLD_SIZE
					then
						local dstId = TowerId.new(nx, ny)
						local dst = WorldView.record(dstId)
						if dst and filterDst(dst) then
							local path = findPath(srcId, dstId, me)
							if path then
								candidates += 1
								local score = -#path * 4
								if TowerType.generatesMobileUnits(dst.t) then
									score += 2
								end
								if (counts[dst.t] or 0) == 0 then
									score += 1
								end
								if score > bestScore then
									best, bestScore = path, score
								end
							end
						end
					end
				end
			end
		end
	end
	return best
end

local function upgradesOf(record: WorldView.TowerRecord): { number }
	local result = {}
	if record.d ~= 0 then
		return result
	end
	local counts = WorldView.towerCounts()
	for _, upgrade in TowerType.upgrades(record.t) do
		if TowerType.hasPrerequisites(upgrade, counts) then
			table.insert(result, upgrade)
		end
	end
	return result
end

local function bestUpgrade(me: number): number?
	local best: number? = nil
	local bestMobile = false
	for id, record in WorldView.records() do
		if record.o == me then
			for _, upgrade in upgradesOf(record) do
				local mobile = TowerType.generatesMobileUnits(upgrade)
				if best == nil or (mobile and not bestMobile) then
					best, bestMobile = id, mobile
				end
			end
		end
	end
	return best
end

local function stillDeployment(path: { number }, me: number): boolean
	local src = WorldView.record(path[1])
	local dst = WorldView.record(path[#path])
	if src == nil or not filterSrc(src, me) or not filterDst(dst) then
		return false
	end
	local again = findPath(path[1], path[#path], me)
	return again ~= nil and table.concat(again, ",") == table.concat(path, ",")
end

local function stillUpgrade(id: number, me: number): boolean
	local record = WorldView.record(id)
	return record ~= nil and record.o == me and #upgradesOf(record) > 0
end

-- `bounding_rectangle.area() > 18²`
local function grownUp(me: number): boolean
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for id, record in WorldView.records() do
		if record.o == me then
			local x, y = TowerId.x(id), TowerId.y(id)
			minX, minY = math.min(minX, x), math.min(minY, y)
			maxX, maxY = math.max(maxX, x), math.max(maxY, y)
		end
	end
	if minX == math.huge then
		return false
	end
	return (maxX - minX + 1) * (maxY - minY + 1) > 18 * 18
end

local function step(me: number)
	if grownUp(me) and not replaying then
		state = { kind = "Done" }
	end
	local s = state
	if s.kind == "WaitingToDeploy" then
		if hasFlag(Alerts.DeployedAnyForce) and hasFlag(Alerts.UpgradedAnyTower) then
			state = { kind = "Done" }
		else
			local upgrade = if hasFlag(Alerts.DeployedAnyForce) then bestUpgrade(me) else nil
			if upgrade then
				state = { kind = "Upgrading", towerId = upgrade }
			else
				local path = bestDeployment(me)
				if path then
					state = { kind = "Deploying", path = path }
				end
			end
		end
	elseif s.kind == "Deploying" then
		if hasFlag(Alerts.DeployedAnyForce) then
			state = { kind = "WaitingToUpgrade" }
		elseif not stillDeployment(s.path, me) then
			state = { kind = "WaitingToDeploy" }
			step(me)
		end
	elseif s.kind == "WaitingToUpgrade" then
		if hasFlag(Alerts.UpgradedAnyTower) then
			state = { kind = "Done" }
		else
			local upgrade = bestUpgrade(me)
			if upgrade then
				state = { kind = "Upgrading", towerId = upgrade }
			end
		end
	elseif s.kind == "Upgrading" then
		if hasFlag(Alerts.UpgradedAnyTower) then
			state = { kind = "Done" }
		elseif not stillUpgrade(s.towerId, me) then
			state = { kind = "WaitingToUpgrade" }
			step(me)
		end
	end
end

local function marker(name: string, size: Vector3, shape: Enum.PartType): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = Theme.colors.crown
	p.Parent = WorldView.towersFolder().Parent
	return p
end

-- Hesap bağlantısı: öğretici bir kez gösterilir, bitince kaydedilir.
function Tutorial.configure(done: () -> boolean, finished: () -> ())
	isDone = done
	onDone = finished
end

-- Ayarlar: öğreticiyi baştan göster.
function Tutorial.restart()
	ignoredFlags = flags
	replaying = true
	reported = false
	state = { kind = "WaitingToDeploy" }
end

function Tutorial.init()
	if gui ~= nil then
		return
	end
	local frame = Kit.panel(Nav.left(), UDim2.new(1, 0, 0, 84), true, 14)
	frame.Name = "Tutorial"
	frame.LayoutOrder = 1
	frame.Visible = false

	local badge = Instance.new("TextLabel")
	badge.Name = "Step"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 12, 0.5, 0)
	badge.Size = UDim2.fromOffset(44, 44)
	badge.BackgroundColor3 = Theme.colors.gold
	badge.FontFace = Theme.fonts.heading
	badge.TextColor3 = Theme.colors.onGold
	badge.TextSize = 24
	badge.Parent = frame
	Kit.corner(badge, 22)

	local title = Kit.text(frame, "", "label", nil, UDim2.new(1, -112, 0, 40))
	title.Position = UDim2.fromOffset(68, 4)
	title.LineHeight = 0.9
	local hint = Kit.text(frame, "", "small", Theme.colors.muted, UDim2.new(1, -80, 0, 38))
	hint.Position = UDim2.fromOffset(68, 44)
	hint.LineHeight = 0.9

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(1, 0)
	close.Size = UDim2.fromOffset(44, 44)
	close.BackgroundTransparency = 1
	close.Text = "×"
	close.TextSize = 26
	close.TextColor3 = Theme.colors.muted
	close.FontFace = Theme.fonts.heading
	close.Parent = frame
	close.Activated:Connect(function()
		-- `dismiss_capture` / `dismiss_upgrade`
		local s = state
		if s.kind == "WaitingToDeploy" or s.kind == "Deploying" then
			state = { kind = "WaitingToUpgrade" }
		else
			state = { kind = "Done" }
		end
	end)

	gui = frame
	titleLabel = title
	hintLabel = hint
	stepLabel = badge
end

function Tutorial.applyAlerts(alerts: Alerts.Alerts)
	flags = alerts.flags
end

-- Doğdu / öldü. Ölünce kaynak gibi baştan (`*self = Self::default()`).
function Tutorial.setAlive(value: boolean)
	alive = value
	if not value then
		if state.kind ~= "Done" then
			state = { kind = "WaitingToDeploy" }
		end
		flags = 0
		ignoredFlags = 0
	end
end

local function hideMarkers()
	if ring then
		ring.destroy()
		ring = nil
	end
	if cursor then
		cursor:Destroy()
		cursor = nil
	end
end

function Tutorial.update(dt: number)
	if state.kind == "Done" and not reported then
		reported = true
		replaying = false
		onDone()
	end
	if isDone() and not replaying then
		state = { kind = "Done" }
	end
	local me = WorldView.me()
	timer += dt
	animation = (animation + dt) % 1.6
	if alive and me ~= nil and timer >= 0.5 then
		timer = 0
		step(me)
	end
	local s = state
	local card = gui
	if card == nil then
		return
	end
	local target: number? = nil
	local from: number? = nil
	if alive and s.kind == "Deploying" then
		target, from = s.path[#s.path], s.path[1];
		(stepLabel :: TextLabel).Text = "1"
		(titleLabel :: TextLabel).Text = Strings.tutorialCaptureTitle;
		(hintLabel :: TextLabel).Text = Strings.tutorialCaptureHint
	elseif alive and s.kind == "Upgrading" then
		target = s.towerId;
		(stepLabel :: TextLabel).Text = "2"
		(titleLabel :: TextLabel).Text = Strings.tutorialUpgradeTitle;
		(hintLabel :: TextLabel).Text = Strings.tutorialUpgradeHint
	end
	card.Visible = target ~= nil
	if target == nil then
		hideMarkers()
		return
	end
	-- Hedefte nabız atan ince halka (2026-11-05: dolu neon disk kuleyi boğuyordu; halka dokusu
	-- görünmez bir levhanın üst yüzünde).
	if ring == nil then
		ring = GroundRing.new("TutorialRing", 9, Theme.colors.crown, WorldView.towersFolder())
	end
	local pulse = 1 + 0.12 * math.sin(animation / 1.6 * math.pi * 2)
	local at = WorldView.position(target)
	local r = ring :: GroundRing.Ring
	r.setDiameter(9 * pulse)
	r.setCFrame(CFrame.new(at.X, 0.72, at.Z))
	r.setTransparency(0.15 + 0.25 * (pulse - 0.88) / 0.24)
	-- Sürükleme gösterimi: kaynaktan hedefe kayan nokta.
	if from ~= nil then
		if cursor == nil then
			local c = marker("TutorialCursor", Vector3.new(0.2, 0.2, 0.2), Enum.PartType.Block)
			c.Transparency = 1
			local board = Instance.new("BillboardGui")
			board.Name = "Hand"
			board.Size = UDim2.fromScale(3.6, 3.6)
			board.AlwaysOnTop = true
			board.LightInfluence = 0
			board.Parent = c
			local image = Instance.new("ImageLabel")
			image.BackgroundTransparency = 1
			image.Size = UDim2.fromScale(1, 1)
			image.Image = Icons.hand
			image.Parent = board
			cursor = c
		end
		local t = math.clamp(animation / 1.2, 0, 1)
		local a = WorldView.position(from)
		local c = cursor :: Part
		c.Position = a:Lerp(at, t) + Vector3.new(0, 3, 0)
		local board = c:FindFirstChild("Hand") :: BillboardGui?
		if board then
			board.Enabled = animation <= 1.2
		end
	elseif cursor then
		cursor:Destroy()
		cursor = nil
	end
end

return Tutorial
