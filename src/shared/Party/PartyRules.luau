--!strict
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: common/src/game_constants.rs, client/src/yew_ui/dialog/play_with_friends_dialog.rs (tag 0.1.1)

-- Parti sunucusu (kodiak "Play with friends" → "party server") ortak kuralları. Saf Luau:
-- istemci (bot seçici) ve sunucu (doğrulama) aynı değerleri kullanır, Lune ile test edilir.
--
-- kodiak `GameConstants`: `min_temporary_server_bots = 0`, `max_temporary_server_bots = 8`,
-- `default_temporary_server_bots = 4`. Kiomet bu değerleri değiştirmiyor (`KIOMET_CONSTANTS`
-- `DefaultedGameConstants::new()`). Genel sunucunun otomatik bot sayısı (`Sim/BotRepo`)
-- değişmez; parti sunucusunda `EngineArenaSettings::bots` gibi sabit sayı kullanılır.

local PartyRules = {}

PartyRules.MIN_BOTS = 0
PartyRules.MAX_BOTS = 8
PartyRules.DEFAULT_BOTS = 4
-- `EngineArenaSettings::bot_aggression` varsayılanı (botun oyuncuya açtığı savaşın süre çarpanı).
PartyRules.DEFAULT_AGGRESSION = 1

-- Play Solo zorlukları (proje kararı, 2026-11-06): kurallar aynı, yalnız kaynaktaki iki ayar
-- (`bots`, `bot_aggression`) değişir. Standard kaynağın varsayılanıdır.
export type Difficulty = { bots: number, aggression: number }
PartyRules.DIFFICULTIES = table.freeze({
	relaxed = table.freeze({ bots = 3, aggression = 0.5 }),
	standard = table.freeze({ bots = 4, aggression = 1 }),
	brutal = table.freeze({ bots = 8, aggression = 2 }),
}) :: { [string]: Difficulty }

-- Davet verisi (`ExperienceInviteOptions.LaunchData`) en fazla 200 karakter (Roblox belgesi).
PartyRules.MAX_LAUNCH_DATA = 200

-- Sunucunun istemciye gönderdiği kısa hata kodları. Ham hata metni gönderilmez.
PartyRules.Reason = table.freeze({
	RATE_LIMITED = "RATE_LIMITED",
	INVALID_BOTS = "INVALID_BOTS",
	INVALID_DIFFICULTY = "INVALID_DIFFICULTY",
	WORLD_GONE = "WORLD_GONE",
	NOT_FOUNDER = "NOT_FOUNDER",
	NOT_IN_PARTY = "NOT_IN_PARTY",
	NO_INVITE = "NO_INVITE",
	PARTY_NOT_FOUND = "PARTY_NOT_FOUND",
	PARTY_EXPIRED = "PARTY_EXPIRED",
	PARTY_CLOSED = "PARTY_CLOSED",
	SERVICE_UNAVAILABLE = "SERVICE_UNAVAILABLE",
	TELEPORT_FAILED = "TELEPORT_FAILED",
	TELEPORT_FLOODED = "TELEPORT_FLOODED",
	BUSY = "BUSY",
})

-- İstemciden gelen bot sayısı: tamsayı ve 0..8. Değilse nil.
function PartyRules.validateBots(value: unknown): number?
	if type(value) ~= "number" or value ~= math.floor(value) then
		return nil
	end
	if value < PartyRules.MIN_BOTS or value > PartyRules.MAX_BOTS then
		return nil
	end
	return value
end

-- Kayıttaki saldırganlık: kaynaktaki sınır 0..10.
function PartyRules.validateAggression(value: unknown): number?
	if type(value) ~= "number" or value ~= value or value < 0 or value > 10 then
		return nil
	end
	return value
end

-- Parti kimliği: `HttpService:GenerateGUID(false)` biçimi (36 karakter, onaltılık + tire).
function PartyRules.isPartyId(value: unknown): boolean
	return type(value) == "string" and #value == 36 and string.match(value, "^[%x%-]+$") ~= nil
end

-- Davet verisi biçimi: "party:<id>". JSON yerine düz metin: kod çözücüye gerek yok, 200 sınırına
-- rahat sığar. Geçersizse nil. Kimliğin gerçekten var olduğu sunucuda kayıttan doğrulanır.
local LAUNCH_PREFIX = "party:"

function PartyRules.encodeLaunchData(partyId: string): string
	return LAUNCH_PREFIX .. partyId
end

function PartyRules.parseLaunchData(value: unknown): string?
	if type(value) ~= "string" or #value > PartyRules.MAX_LAUNCH_DATA then
		return nil
	end
	if string.sub(value, 1, #LAUNCH_PREFIX) ~= LAUNCH_PREFIX then
		return nil
	end
	local id = string.sub(value, #LAUNCH_PREFIX + 1)
	if not PartyRules.isPartyId(id) then
		return nil
	end
	return id
end

-- Sunucu türü (`DataModel.PrivateServerId` / `PrivateServerOwnerId`, Roblox belgesi):
-- boş kimlik → genel; dolu kimlik + sahip 0 → ayrılmış (bizim parti sunucumuz); aksi → VIP.
export type ServerKind = "public" | "reserved" | "vip"

function PartyRules.serverKind(privateServerId: string, privateServerOwnerId: number): ServerKind
	if privateServerId == "" then
		return "public"
	end
	if privateServerOwnerId == 0 then
		return "reserved"
	end
	return "vip"
end

return table.freeze(PartyRules)
