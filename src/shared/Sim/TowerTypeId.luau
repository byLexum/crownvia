--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/tower.rs

-- Kiomet'te `common/src/tower.rs` içindeki `enum TowerType` (`#[repr(u8)]`)
-- → bizde bu modül. Sadece kimlikler; veri ve kurallar `TowerType.luau` içinde.
-- Ayrı modül olmasının nedeni: `Unit.luau` Projector'u bilmeli, `TowerType.luau` ise
-- `Unit.luau`'ya bağlı (döngüsel require olmasın).
--
-- Değerler Rust'taki bildirim sırasıyla aynıdır (0'dan başlar). Sıra önemli:
-- `TowerType::generate` ve `Ord` bu sıraya dayanır.

export type TowerTypeId = number

local NAMES: { string } = {
	"Airfield",
	"Armory",
	"Artillery",
	"Barracks",
	"Bunker",
	"Centrifuge",
	"City",
	"Cliff",
	"Ews",
	"Factory",
	"Generator",
	"Headquarters",
	"Helipad",
	"Launcher",
	"Mine",
	"Projector",
	"Quarry",
	"Radar",
	"Rampart",
	"Reactor",
	"Refinery",
	"Rocket",
	"Runway",
	"Satellite",
	"Silo",
	"Town",
	"Village",
}

local TowerTypeId = {
	Airfield = 0,
	Armory = 1,
	Artillery = 2,
	Barracks = 3,
	Bunker = 4,
	Centrifuge = 5,
	City = 6,
	Cliff = 7,
	Ews = 8,
	Factory = 9,
	Generator = 10,
	Headquarters = 11,
	Helipad = 12,
	Launcher = 13,
	Mine = 14,
	Projector = 15,
	Quarry = 16,
	Radar = 17,
	Rampart = 18,
	Reactor = 19,
	Refinery = 20,
	Rocket = 21,
	Runway = 22,
	Satellite = 23,
	Silo = 24,
	Town = 25,
	Village = 26,

	-- `std::mem::variant_count::<TowerType>()`
	COUNT = #NAMES,
}

function TowerTypeId.name(id: TowerTypeId): string
	return NAMES[id + 1]
end

return table.freeze(TowerTypeId)
