--!strict
-- Oyuncuların kuşandığı kozmetikler (sunucunun `Cosmetics` yayını; Kiomet'te yok,
-- `docs/HESAP_MAGAZA.md`). Bağımlılıksız: WorldView, Effects ve Leaderboard okur.
-- Yalnız görünüm: sahip rengi, işaretin yeri ve boyu değişmez.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticArt = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Art"):WaitForChild("CosmeticArt")
)

local Cosmetics = {}

local bySimId: { [number]: { [string]: string } } = {}
local listeners: { () -> () } = {}

-- `Cosmetics` mesajı: `players = { [simId (string)] = { crown?, capture?, frame? } }`.
function Cosmetics.apply(players: any)
	if type(players) ~= "table" then
		return
	end
	local next: { [number]: { [string]: string } } = {}
	for key, value in players do
		local simId = tonumber(key)
		if simId and type(value) == "table" then
			local entry: { [string]: string } = {}
			for slot, id in value do
				if type(slot) == "string" and type(id) == "string" then
					entry[slot] = id
				end
			end
			next[simId] = entry
		end
	end
	bySimId = next
	for _, listener in listeners do
		listener()
	end
end

-- Kuşanılan ürün kimliği (yoksa nil → varsayılan görünüm).
function Cosmetics.get(simId: number, slot: string): string?
	local entry = bySimId[simId]
	return if entry then entry[slot] else nil
end

-- Kuşanılan ürünün görseli (yoksa nil).
function Cosmetics.image(simId: number, slot: string): string?
	local id = Cosmetics.get(simId, slot)
	return if id then CosmeticArt.images[id] else nil
end

function Cosmetics.onChanged(listener: () -> ())
	table.insert(listeners, listener)
end

return Cosmetics
