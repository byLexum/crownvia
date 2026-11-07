--!strict
-- Karşılama hunisi adımları (Kiomet'te yok; `docs/ANALIZ_DEGERLENDIRMESI.md`). Saf Luau.
-- Roblox atlanan adımları tamamlanmış sayar. Bu yüzden adım yalnız sırası gelince kaydedilir:
-- fetih yapmadan ölen oyuncu "fetih yaptı" görünmesin. Ölüm ve yeniden oynama ayrıca özel olay
-- olarak sayılır (`src/server/Analytics.luau`).

local Funnel = {}

export type Step = "Joined" | "Spawned" | "Captured" | "Upgraded" | "Died" | "PlayedAgain"

Funnel.STEPS = { "Joined", "Spawned", "Captured", "Upgraded", "Died", "PlayedAgain" } :: { Step }

-- `reached` son kaydedilen adım numarası (başta 0). Adım sırası geldiyse numarasını döner.
function Funnel.advance(reached: number, step: Step): number?
	local index = table.find(Funnel.STEPS, step)
	if index == reached + 1 then
		return index
	end
	return nil
end

return Funnel
