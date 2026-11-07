--!strict
-- Durum kanalı: sunucu → istemci, tek RemoteEvent, yalnız değişen veri (CLAUDE.md kural 4 ve 6).
-- Fark üretimi saf modülde (Shared/Net/Snapshot); burası yalnız gönderir.
-- Paket biçimi: docs/API.md

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Game = require(Shared:WaitForChild("Sim"):WaitForChild("Game"))
local Snapshot = require(Shared:WaitForChild("Net"):WaitForChild("Snapshot"))

type Game = Game.Game

export type TowerRecord = Snapshot.TowerRecord
export type ForceRecord = Snapshot.ForceRecord

local Replication = {}
Replication.__index = Replication

export type Replication = typeof(setmetatable(
	{} :: {
		remote: RemoteEvent,
		clients: { [Player]: Snapshot.ClientState },
		-- Menüde bekleyen oyuncu → izlediği bot.
		spectating: { [Player]: number },
	},
	Replication
))

function Replication.new(remotes: Folder): Replication
	local remote = Instance.new("RemoteEvent")
	remote.Name = "State"
	remote.Parent = remotes
	return setmetatable({ remote = remote, clients = {}, spectating = {} }, Replication)
end

-- İstemciyi (yeniden) tanıt: tam durum yeniden gönderilir.
function Replication.hello(self: Replication, player: Player, simId: number, tick: number)
	self.spectating[player] = nil
	self.clients[player] = Snapshot.newClient(simId)
	self.remote:FireClient(player, { kind = "Hello", you = simId, tick = tick })
end

-- Komut sonucu (şimdilik yalnız başarısız Spawn): istemci bekleme ekranından çıkıp yeniden dener.
-- `reason` istemciye giden güvenli, kısa bir koddur; ham hata metni gönderilmez.
function Replication.spawnFailed(self: Replication, player: Player, reason: string)
	self.remote:FireClient(player, { kind = "SpawnFailed", reason = reason })
end

-- Simülasyon dışı mesaj (parti durumu) aynı durum kanalından gider.
function Replication.send(self: Replication, player: Player, message: { [string]: any })
	self.remote:FireClient(player, message)
end

function Replication.remove(self: Replication, player: Player)
	self.clients[player] = nil
	self.spectating[player] = nil
end

-- Ana menü arkası canlı dünya: henüz doğmamış oyuncu `target` botun gördüğünü alır. Doğan ya da
-- ölü oyuncuya dokunmaz (`hello` izlemeyi bitirir). Hedef yoksa mevcut görünüm kalır.
function Replication.spectate(
	self: Replication,
	players: { [Player]: number },
	target: number?,
	tick: number
)
	if target == nil then
		return
	end
	for player in players do
		local inMenu = self.clients[player] == nil or self.spectating[player] ~= nil
		if inMenu and self.spectating[player] ~= target then
			self.spectating[player] = target
			self.clients[player] = Snapshot.newSpectator(target)
			self.remote:FireClient(player, { kind = "Spectate", you = target, tick = tick })
		end
	end
end

-- Her simülasyon adımından sonra çağrılır.
function Replication.update(self: Replication, game: Game)
	for player, client in self.clients do
		local message = Snapshot.build(client, game)
		if message ~= nil then
			self.remote:FireClient(player, message)
		end
	end
end

return Replication
