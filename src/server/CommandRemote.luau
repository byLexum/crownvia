--!strict
-- Komut kanalı: istemci → sunucu, tek RemoteEvent (CLAUDE.md mimari kural 3 ve 6).
-- Komut seti Kiomet `common/src/protocol.rs` `Command` ile aynı. `SetViewport` uygulanmaz: sunucu
-- görüşü kule bazında filtreler (CLAUDE.md, bilinçli sapma), kamera alanına gerek yok.
-- Her komut sunucuda doğrulanır: şekil, tip, hız sınırı. Kural doğrulaması Sim/Game içinde.
-- Ayrıntılar: docs/API.md

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type Handler = (player: Player, payload: { [string]: any }) -> string?
-- Reddedilen komut: `reason` hız sınırında "rate limited", aksi hâlde işleyicinin hata metni.
export type OnRejected = (player: Player, kind: string, reason: string) -> ()

local CommandRemote = {}

-- Oyuncu başına basit jeton kovası.
local BUCKET_SIZE = 10
local REFILL_PER_SECOND = 10

local KNOWN_KINDS = {
	Alliance = true,
	BuyItem = true,
	DeployForce = true,
	EquipItem = true,
	-- Parti sunucusu (kodiak "Play with friends"), oyun kuralı değil: `PartyService`.
	PartyCreate = true,
	PartyJoin = true,
	PartyLeave = true,
	PartySetBots = true,
	-- Kalıcı sıralama (oyun kuralı değil): `Rankings`.
	RankingsGet = true,
	-- Ses tercihi ve öğretici durumu (hesap ayarı, oyun kuralı değil): `InventoryService`.
	SetAudio = true,
	SetGraphics = true,
	SetTutorialDone = true,
	SetSupplyLine = true,
	SetViewport = true,
	Spawn = true,
	Upgrade = true,
	-- Genel sunucu listesinden katılma (oyun kuralı değil): `PartyService`.
	WorldJoin = true,
}

type Bucket = { tokens: number, updated: number }

function CommandRemote.remotesFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = "Remotes"
		created.Parent = ReplicatedStorage
		folder = created
	end
	return folder :: Folder
end

local function takeToken(buckets: { [Player]: Bucket }, player: Player): boolean
	local now = os.clock()
	local bucket = buckets[player]
	if bucket == nil then
		bucket = { tokens = BUCKET_SIZE, updated = now }
		buckets[player] = bucket
	end
	bucket.tokens =
		math.min(BUCKET_SIZE, bucket.tokens + (now - bucket.updated) * REFILL_PER_SECOND)
	bucket.updated = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

-- `handlers[kind](player, payload)`: hata mesajı ya da nil döner.
function CommandRemote.start(handlers: { [string]: Handler }, onRejected: OnRejected?): RemoteEvent
	local remote = Instance.new("RemoteEvent")
	remote.Name = "Command"
	remote.Parent = CommandRemote.remotesFolder()

	local buckets: { [Player]: Bucket } = {}
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)

	remote.OnServerEvent:Connect(function(player: Player, payload: unknown)
		if type(payload) ~= "table" then
			return
		end
		local message = payload :: { [string]: any }
		local kind = message.kind
		if type(kind) ~= "string" or not KNOWN_KINDS[kind] then
			return
		end
		if not takeToken(buckets, player) then
			if onRejected then
				onRejected(player, kind, "rate limited")
			end
			return
		end
		local handler = handlers[kind]
		if handler == nil then
			warn(string.format("[robgame] %s: command %s not implemented yet", player.Name, kind))
			return
		end
		local err = handler(player, message)
		if err ~= nil then
			warn(string.format("[robgame] %s: %s resulted in %s", player.Name, kind, err))
			if onRejected then
				onRejected(player, kind, err)
			end
		end
	end)

	return remote
end

return CommandRemote
