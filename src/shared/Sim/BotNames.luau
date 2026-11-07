--!strict
-- Bot takma adları. Kaynakta kodiak `server/src/service/bot_names.txt` var; o liste başka
-- markalara ait karakter adları içerdiği için (C-3PO, Siri, GLaDOS vb.) kullanılmadı.
-- Bu liste bu projeye ait, genel kelimelerden oluşur. Kural değil, yalnız görünen ad.

local NAMES: { string } = {
	"Android",
	"Atom",
	"Axle",
	"Bolt",
	"Bot",
	"Byte",
	"Chip",
	"Circuit",
	"Cobalt",
	"Cog",
	"Cyborg",
	"Droid",
	"Drone",
	"Dynamo",
	"Echo",
	"Flux",
	"Gear",
	"Gizmo",
	"Ion",
	"Mech",
	"Mk II",
	"Neon",
	"Nova",
	"Orbit",
	"Otto",
	"Piston",
	"Pixel",
	"Quark",
	"Radar",
	"Rex",
	"Rivet",
	"Robot",
	"Sentinel",
	"Servo",
	"Sonar",
	"Spark",
	"Sprocket",
	"Turbo",
	"Unit 7",
	"Vector",
	"Widget",
	"Zinc",
}

local BotNames = {}

-- kodiak `random_bot_name`: listeden eşit olasılıkla bir ad.
function BotNames.random(rng: () -> number): string
	return NAMES[math.floor(rng() * #NAMES) + 1]
end

return table.freeze(BotNames)
