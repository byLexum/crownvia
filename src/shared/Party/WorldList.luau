--!strict
-- Ana ekrandaki genel sunucu listesi: kayıt doğrulama, sıralama, görünen ad. Saf Luau, Lune testli.
-- Roblox bağlantısı `src/server/WorldService.luau`. Dünyalar kalıcıdır (kaynakta tur yok): liste
-- geri sayım değil, açık sunucuları ve doluluğunu gösterir. Kaynakta yok, oyun kuralına dokunmaz.

local WorldList = {}

WorldList.ROWS = 3
-- Sunucu kendini bu aralıkla yazar; kayıt ömrü bunun iki katından uzun.
WorldList.PUBLISH_SECS = 30
WorldList.RECORD_TTL = 90
WorldList.REFRESH_SECS = 15
WorldList.STALE_SECS = 75
-- Bulunulan sunucunun liste kimliği (katılmak için ışınlama gerekmez).
WorldList.HERE = "here"

local NAMES = {
	"Iron Coast",
	"Red Ridge",
	"Steel Bay",
	"Delta Point",
	"Sand Fort",
	"Pine Front",
	"Gold Reach",
	"Storm Line",
	"Ash Valley",
	"Blue Harbor",
	"Stone Gate",
	"Radar Hill",
}

export type Entry = { id: string, players: number, max: number, leader: string?, at: number }
export type Row = {
	id: string,
	name: string,
	players: number,
	max: number,
	leader: string?,
	here: boolean,
}

-- Depodan gelen değer bizim kaydımız mı.
function WorldList.validate(id: unknown, value: any, now: number): Entry?
	if type(id) ~= "string" or id == "" or #id > 64 or type(value) ~= "table" then
		return nil
	end
	local players, max, at = value.players, value.max, value.at
	if type(players) ~= "number" or type(max) ~= "number" or type(at) ~= "number" then
		return nil
	end
	if max <= 0 or players < 0 or now - at > WorldList.STALE_SECS then
		return nil
	end
	local leader = if type(value.leader) == "string" then value.leader else nil
	return { id = id, players = players, max = max, leader = leader, at = at }
end

-- Kimlikten sabit görünen ad: aynı sunucu listede hep aynı adla görünür.
function WorldList.name(id: string): string
	local sum = 0
	for i = 1, #id do
		sum = (sum * 31 + string.byte(id, i)) % 65521
	end
	return NAMES[sum % #NAMES + 1]
end

local function toRow(entry: Entry, here: boolean): Row
	return {
		id = if here then WorldList.HERE else entry.id,
		name = WorldList.name(entry.id),
		players = entry.players,
		max = entry.max,
		leader = entry.leader,
		here = here,
	}
end

-- Satırlar: bulunulan sunucu başta, diğerleri en kalabalıktan boşa. Dolu sunucu gösterilmez.
function WorldList.rows(here: Entry?, others: { Entry }): { Row }
	local sorted = table.clone(others)
	table.sort(sorted, function(a, b)
		if a.players ~= b.players then
			return a.players > b.players
		end
		return a.id < b.id
	end)
	local rows: { Row } = {}
	if here ~= nil then
		table.insert(rows, toRow(here, true))
	end
	for _, entry in sorted do
		if #rows >= WorldList.ROWS then
			break
		end
		local isSelf = here ~= nil and entry.id == here.id
		if not isSelf and entry.players < entry.max then
			table.insert(rows, toRow(entry, false))
		end
	end
	-- Ad havuzu küçük: aynı ad iki satıra düşerse sıra numarası eklenir.
	local seen: { [string]: number } = {}
	for _, row in rows do
		local count = (seen[row.name] or 0) + 1
		seen[row.name] = count
		if count > 1 then
			row.name ..= " " .. count
		end
	end
	return rows
end

return WorldList
