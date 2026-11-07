--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: client/src/visible.rs

-- Kiomet'te `client/src/visible.rs` `Visible::update` / `increment_refs` → bizde bu modül.
-- Bilinçli sapma (CLAUDE.md): kaynakta bu hesap istemcide yapılır; bizde sunucu yalnız
-- görünen kuleleri gönderir. Kural aynıdır:
--   - oyuncunun her kulesi `iter_radius(sensor_radius)` içini görür,
--   - aktif olmayan (yükseltmedeki) kule Mine'ın yarıçapıyla (varsayılan 12) görür.
-- Yalnız üretilmiş (dünyada var olan) kuleler döner.

local Tower = require("./Tower")
local TowerId = require("./TowerId")
local TowerType = require("./TowerType")
local TowerTypeId = require("./TowerTypeId")
local World = require("./World")

type World = World.World
type TowerId = TowerId.TowerId

local Visibility = {}

-- `playerTowers`: oyuncunun sahip olduğu kule id'leri (Game.PlayerData.towers).
function Visibility.visibleTowers(
	world: World,
	playerTowers: { [TowerId]: boolean }
): { [TowerId]: boolean }
	local visible: { [TowerId]: boolean } = {}
	for id in playerTowers do
		local tower = World.get(world, id)
		if tower ~= nil then
			local sensorType = if Tower.active(tower) then tower.towerType else TowerTypeId.Mine
			for _, seen in TowerId.iterRadius(id, TowerType.sensorRadius(sensorType)) do
				if World.contains(world, seen) then
					visible[seen] = true
				end
			end
		end
	end
	return visible
end

return table.freeze(Visibility)
