--!strict
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: server/src/service/invitation_repo.rs, server/src/service/realm_repo.rs, client/src/yew_ui/dialog/play_with_friends_dialog.rs (tag 0.1.1)

-- Parti sunucusu mantığı (kodiak geçici "party server" + davet). Roblox servislerine dokunmaz:
-- kayıt deposu (MemoryStore), ışınlama (TeleportService) ve saat dışarıdan verilir. Böylece
-- Lune ile sahte depo/ışınlamayla test edilir. Roblox bağlantısı: `src/server/PartyService.luau`.
--
-- Akış:
--   Genel sunucu: `create` → kayıt "pending" → yeni `ReservedServerId` ile ışınla.
--   Parti sunucusu: `loadRoom` → kayıt "open", bot sayısı kayıttan; `heartbeat` kaydı canlı tutar;
--     son oyuncu çıkınca `close` → "closed".
--   Davetli: davet verisi (`LaunchData`) yalnız ipucu → `setPendingJoin`; `join` kaydı depodan
--     okur, durumunu doğrular ve kayıttaki `ReservedServerId` ile ışınlar.
-- Kaynakta parti sunucusu boşalınca kapanır; davet kodu sunucu kaydına bağlıdır. Bizde aynısı.

local PartyRules = require("./PartyRules")

local Reason = PartyRules.Reason

export type State = "pending" | "open" | "closed"

-- Depodaki parti kaydı. Yalnız sunucular yazar; istemci hiçbir alanı belirlemez.
export type Record = {
	v: number,
	id: string,
	-- `TeleportOptions.ReservedServerId`: ilk ışınlama sunucuyu açar, sonrakiler aynı sunucuya gider.
	rsid: string,
	-- Ayrılmış sunucunun `game.PrivateServerId` değeri (`TeleportAsyncResult.PrivateServerId`).
	psid: string?,
	founder: number,
	bots: number,
	-- `bot_aggression`; yoksa varsayılan.
	agg: number?,
	state: State,
	-- Bu zamana (os.time) kadar canlı sayılır; parti sunucusu düzenli olarak ileri alır.
	alive: number,
}

export type Store = {
	-- (başarılı mı, değer). Başarısız → servis yok.
	get: (key: string) -> (boolean, any),
	set: (key: string, value: any, ttl: number) -> boolean,
	-- `fn` nil dönerse yazma iptal. (başarılı mı, yeni değer)
	update: (key: string, fn: (any) -> any, ttl: number) -> (boolean, any),
}

-- Işınlama sonucu. Hata fırlatmaz; çağıran pcall ile sarar.
export type TeleportOutcome = { ok: boolean, privateServerId: string?, flooded: boolean? }

export type Deps<P> = {
	store: Store,
	now: () -> number,
	clock: () -> number,
	newId: () -> string,
	userId: (player: P) -> number,
	-- `reservedServerId` nil → genel sunucuya dönüş.
	teleport: (
		players: { P },
		reservedServerId: string?,
		data: { [string]: any }?
	) -> TeleportOutcome,
	wait: (seconds: number) -> (),
}

export type Room = { partyId: string, founder: number, bots: number, aggression: number }

export type Core<P> = {
	deps: Deps<P>,
	lastRequest: { [P]: number },
	busy: { [P]: boolean },
	-- Davet verisinden gelen, henüz doğrulanmamış parti kimliği.
	pendingJoin: { [P]: string },
	-- Yalnız parti sunucusunda dolu.
	room: Room?,
}

local PartyCore = {}

PartyCore.VERSION = 1
-- Aynı oyuncudan iki parti isteği arası en az bu kadar (sn). Işınlama ve depo çağrısı pahalı.
PartyCore.COOLDOWN = 3
-- Kurulan ama sunucusu henüz açılmamış partinin canlı sayıldığı süre (sn).
PartyCore.PENDING_SECS = 120
-- Parti sunucusu kaydı bu aralıkla yeniler; yenilenmezse ALIVE_SECS sonra süresi dolmuş sayılır.
PartyCore.HEARTBEAT_SECS = 60
PartyCore.ALIVE_SECS = 180
-- Depodaki kayıt ömrü: kapanmış/süresi dolmuş davete "kapandı" diyebilmek için canlılıktan uzun.
PartyCore.STORE_TTL = 3600
-- Ilk denemeyle birlikte en fazla bu kadar ışınlama denemesi (Roblox belgesi: yeniden dene).
PartyCore.TELEPORT_ATTEMPTS = 3
PartyCore.TELEPORT_RETRY_SECS = 1
PartyCore.FLOODED_RETRY_SECS = 15

local function partyKey(id: string): string
	return "p:" .. id
end

local function serverKey(privateServerId: string): string
	return "s:" .. privateServerId
end

function PartyCore.new<P>(deps: Deps<P>): Core<P>
	return { deps = deps, lastRequest = {}, busy = {}, pendingJoin = {}, room = nil }
end

-- Depodan gelen değer bizim kaydımız mı (şekil denetimi; eski sürüm kayıtları reddedilir).
local function asRecord(value: any): Record?
	if type(value) ~= "table" or value.v ~= PartyCore.VERSION then
		return nil
	end
	if not PartyRules.isPartyId(value.id) or not PartyRules.isPartyId(value.rsid) then
		return nil
	end
	if type(value.founder) ~= "number" or PartyRules.validateBots(value.bots) == nil then
		return nil
	end
	if value.state ~= "pending" and value.state ~= "open" and value.state ~= "closed" then
		return nil
	end
	if type(value.alive) ~= "number" then
		return nil
	end
	if value.agg ~= nil and PartyRules.validateAggression(value.agg) == nil then
		return nil
	end
	return value :: Record
end

-- Davetle katılmaya uygun mu: nil → uygun, aksi hâlde hata kodu.
function PartyCore.joinable(record: Record?, now: number): string?
	if record == nil then
		return Reason.PARTY_NOT_FOUND
	end
	if record.state == "closed" then
		return Reason.PARTY_CLOSED
	end
	if now > record.alive then
		return Reason.PARTY_EXPIRED
	end
	return nil
end

-- Hız sınırı + aynı anda tek istek. nil → devam edilebilir (kilit alındı), aksi hâlde hata kodu.
local function acquire<P>(core: Core<P>, player: P): string?
	if core.busy[player] then
		return Reason.BUSY
	end
	local now = core.deps.clock()
	local last = core.lastRequest[player]
	if last ~= nil and now - last < PartyCore.COOLDOWN then
		return Reason.RATE_LIMITED
	end
	core.lastRequest[player] = now
	core.busy[player] = true
	return nil
end

local function release<P>(core: Core<P>, player: P)
	core.busy[player] = nil
end

-- Yeniden denemeli ışınlama. Başarısız → hata kodu.
local function teleport<P>(
	core: Core<P>,
	players: { P },
	reservedServerId: string?,
	data: { [string]: any }?
): (TeleportOutcome?, string?)
	local flooded = false
	for attempt = 1, PartyCore.TELEPORT_ATTEMPTS do
		local outcome = core.deps.teleport(players, reservedServerId, data)
		if outcome.ok then
			return outcome, nil
		end
		flooded = outcome.flooded == true
		if attempt < PartyCore.TELEPORT_ATTEMPTS then
			core.deps.wait(
				if flooded then PartyCore.FLOODED_RETRY_SECS else PartyCore.TELEPORT_RETRY_SECS
			)
		end
	end
	return nil, if flooded then Reason.TELEPORT_FLOODED else Reason.TELEPORT_FAILED
end

-- "Botlara karşı" ve "Arkadaşlarla": yeni parti kur, kurucuyu ışınla. `invite` yalnız arayüz
-- ipucudur (varınca davet penceresi açılsın); kuralı değiştirmez. `difficulty` verilirse (Play Solo)
-- bot sayısı ve saldırganlık tablodan gelir, oyuncu varınca doğrudan oyuna girer.
function PartyCore.create<P>(
	core: Core<P>,
	player: P,
	botsValue: unknown,
	invite: boolean,
	difficulty: unknown
): string?
	local bots: number? = nil
	local aggression = PartyRules.DEFAULT_AGGRESSION
	if difficulty ~= nil then
		local entry = if type(difficulty) == "string"
			then PartyRules.DIFFICULTIES[difficulty]
			else nil
		if entry == nil then
			return Reason.INVALID_DIFFICULTY
		end
		bots, aggression = entry.bots, entry.aggression
	else
		bots = PartyRules.validateBots(botsValue)
	end
	if bots == nil then
		return Reason.INVALID_BOTS
	end
	local denied = acquire(core, player)
	if denied ~= nil then
		return denied
	end
	local deps = core.deps
	local record: Record = {
		v = PartyCore.VERSION,
		id = deps.newId(),
		rsid = deps.newId(),
		psid = nil,
		founder = deps.userId(player),
		bots = bots,
		agg = aggression,
		state = "pending",
		alive = deps.now() + PartyCore.PENDING_SECS,
	}
	if not deps.store.set(partyKey(record.id), record, PartyCore.STORE_TTL) then
		release(core, player)
		return Reason.SERVICE_UNAVAILABLE
	end
	local outcome, err = teleport(
		core,
		{ player },
		record.rsid,
		{ party = record.id, invite = invite, autoPlay = difficulty ~= nil }
	)
	if outcome == nil then
		release(core, player)
		return err
	end
	-- Parti sunucusu kendi kaydını `game.PrivateServerId` ile bulsun (davet ipucuna güvenmeden).
	local psid = outcome.privateServerId
	if psid ~= nil and psid ~= "" then
		deps.store.update(partyKey(record.id), function(value)
			local current = asRecord(value)
			if current == nil or current.psid ~= nil then
				return nil
			end
			current.psid = psid
			return current
		end, PartyCore.STORE_TTL)
		deps.store.set(serverKey(psid), record.id, PartyCore.STORE_TTL)
	end
	release(core, player)
	return nil
end

-- Davet verisi geldi (oyuncu genel sunucuya davetle girdi). Yalnız ipucu olarak saklanır.
function PartyCore.setPendingJoin<P>(core: Core<P>, player: P, launchData: unknown): boolean
	local id = PartyRules.parseLaunchData(launchData)
	if id == nil then
		return false
	end
	core.pendingJoin[player] = id
	return true
end

function PartyCore.hasPendingJoin<P>(core: Core<P>, player: P): boolean
	return core.pendingJoin[player] ~= nil
end

-- Davetli oyuncuyu partisine götür. Kimlik istemciden değil, davet verisinden gelir; kayıt
-- depodan okunur ve durumu doğrulanır. Başarısız ışınlamada yeniden denenebilsin diye
-- bekleyen davet silinmez; kapanmış/bulunamayan davette silinir.
function PartyCore.join<P>(core: Core<P>, player: P): string?
	local id = core.pendingJoin[player]
	if id == nil then
		return Reason.NO_INVITE
	end
	local denied = acquire(core, player)
	if denied ~= nil then
		return denied
	end
	local deps = core.deps
	local ok, value = deps.store.get(partyKey(id))
	if not ok then
		release(core, player)
		return Reason.SERVICE_UNAVAILABLE
	end
	local record = asRecord(value)
	local reason = PartyCore.joinable(record, deps.now())
	if reason ~= nil then
		core.pendingJoin[player] = nil
		release(core, player)
		return reason
	end
	local _, err = teleport(
		core,
		{ player },
		(record :: Record).rsid,
		{ party = id, invite = false }
	)
	release(core, player)
	return err
end

-- Partiden çık: genel sunucuya dön.
function PartyCore.leave<P>(core: Core<P>, player: P): string?
	if core.room == nil then
		return Reason.NOT_IN_PARTY
	end
	local denied = acquire(core, player)
	if denied ~= nil then
		return denied
	end
	local _, err = teleport(core, { player }, nil, nil)
	release(core, player)
	return err
end

-- Parti sunucusu açılışı: kayıt önce `game.PrivateServerId` dizininden aranır. Bulunamazsa
-- (`TeleportAsyncResult.PrivateServerId` boş kaldıysa) ilk oyuncunun ışınlama verisindeki
-- kimlik denenir; kayıtta başka bir sunucu kimliği yazılıysa reddedilir.
function PartyCore.loadRoom<P>(core: Core<P>, privateServerId: string, hintPartyId: unknown): Room?
	local deps = core.deps
	local id: string? = nil
	local okIndex, indexed = deps.store.get(serverKey(privateServerId))
	if okIndex and PartyRules.isPartyId(indexed) then
		id = indexed
	elseif PartyRules.isPartyId(hintPartyId) then
		id = hintPartyId :: string
	end
	if id == nil then
		return nil
	end
	local now = deps.now()
	local ok, value = deps.store.update(partyKey(id), function(current)
		local record = asRecord(current)
		if record == nil then
			return nil
		end
		if record.psid ~= nil and record.psid ~= privateServerId then
			return nil
		end
		record.psid = privateServerId
		record.state = "open"
		record.alive = now + PartyCore.ALIVE_SECS
		return record
	end, PartyCore.STORE_TTL)
	local record = if ok then asRecord(value) else nil
	if record == nil or record.psid ~= privateServerId then
		return nil
	end
	deps.store.set(serverKey(privateServerId), record.id, PartyCore.STORE_TTL)
	local room = {
		partyId = record.id,
		founder = record.founder,
		bots = record.bots,
		aggression = record.agg or PartyRules.DEFAULT_AGGRESSION,
	}
	core.room = room
	return room
end

-- Kaydı canlı tut (parti sunucusunda HEARTBEAT_SECS aralıkla).
function PartyCore.heartbeat<P>(core: Core<P>): boolean
	local room = core.room
	if room == nil then
		return false
	end
	local now = core.deps.now()
	local ok = core.deps.store.update(partyKey(room.partyId), function(current)
		local record = asRecord(current)
		if record == nil or record.state == "closed" then
			return nil
		end
		record.alive = now + PartyCore.ALIVE_SECS
		return record
	end, PartyCore.STORE_TTL)
	return ok
end

-- Kurucu bot sayısını değiştirir. (hata kodu, yeni sayı)
function PartyCore.setBots<P>(core: Core<P>, player: P, botsValue: unknown): (string?, number?)
	local room = core.room
	if room == nil then
		return Reason.NOT_IN_PARTY, nil
	end
	if core.deps.userId(player) ~= room.founder then
		return Reason.NOT_FOUNDER, nil
	end
	local bots = PartyRules.validateBots(botsValue)
	if bots == nil then
		return Reason.INVALID_BOTS, nil
	end
	room.bots = bots
	-- Depo yazılamasa da oda ayarı geçerli; kayıt yalnız bilgi amaçlı güncellenir.
	core.deps.store.update(partyKey(room.partyId), function(current)
		local record = asRecord(current)
		if record == nil then
			return nil
		end
		record.bots = bots
		return record
	end, PartyCore.STORE_TTL)
	return nil, bots
end

-- Oda boşaldı ya da sunucu kapanıyor: davet artık kabul edilmez.
function PartyCore.close<P>(core: Core<P>): boolean
	local room = core.room
	if room == nil then
		return false
	end
	local ok = core.deps.store.update(partyKey(room.partyId), function(current)
		local record = asRecord(current)
		if record == nil then
			return nil
		end
		record.state = "closed"
		return record
	end, PartyCore.STORE_TTL)
	return ok
end

-- Oda boşaldıktan sonra yeniden biri gelirse (ör. ışınlama sürerken) kayıt yeniden açılır.
function PartyCore.reopen<P>(core: Core<P>, privateServerId: string): boolean
	local room = core.room
	if room == nil then
		return false
	end
	return PartyCore.loadRoom(core, privateServerId, room.partyId) ~= nil
end

-- `TeleportService.TeleportInitFailed` sonucu → istemci hata kodu.
function PartyCore.teleportFailedReason(resultName: string): string
	if resultName == "Flooded" then
		return Reason.TELEPORT_FLOODED
	end
	return Reason.TELEPORT_FAILED
end

function PartyCore.forget<P>(core: Core<P>, player: P)
	core.lastRequest[player] = nil
	core.busy[player] = nil
	core.pendingJoin[player] = nil
end

return PartyCore
