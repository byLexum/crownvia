--!strict
-- Profil servisi: ProfileCore'u DataStore'a bağlar, oyuncu giriş/çıkışında yükler/kaydeder.
-- Kiomet'te yok (bkz. `src/shared/Account/ProfileData.luau`, `docs/HESAP_MAGAZA.md`).
--
--   - Yükleme oyuncu girince arka planda; kilitliyse ya da depo hatasında birkaç kez yeniden dener.
--     Olmazsa oyuncu oynar ama profil "failed": mağaza, kuşanma ve kalıcı ödüller kapalı.
--   - Kayıt: SAVE_INTERVAL'de bir (kilit tazelenir), çıkışta ve sunucu kapanırken (kilit bırakılır).
--   - Kayıt "lost" dönerse (başka sunucu devraldı) bu sunucu o profili bir daha yazmaz.
--   - Yer yayınlı değilse (`PlaceId == 0`, Studio) ya da Studio'da DataStore erişimi yoksa bellek
--     içi depo: sunucu kapanınca silinir. Canlı sunucuda bellek yedeği yoktur.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Account = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Account")
local ProfileCore = require(Account:WaitForChild("ProfileCore"))
local ProfileData = require(Account:WaitForChild("ProfileData"))

local Profiles = {}

local STORE_NAME = "CrownviaProfiles_v1"
local LOAD_ATTEMPTS = 5
local LOAD_RETRY_SECONDS = 4
local CLOSE_TIMEOUT = 25

export type State = "loading" | "ready" | "failed" | "lost"

type Entry = { state: State, profile: ProfileData.Profile? }

local entries: { [Player]: Entry } = {}
local session: ProfileCore.Session? = nil
local changedEvent = Instance.new("BindableEvent")
local beforeRelease: { (Player) -> () } = {}

-- Profil değişti / hazır oldu (istemciye gönderim, kozmetik yayını bunu dinler).
Profiles.changed = changedEvent.Event

local function memoryStore(): ProfileCore.Store
	local values: { [string]: any } = {}
	return {
		update = function(key: string, transform: (any) -> any?, _userId: number): (boolean, any)
			local new = transform(ProfileData.copy(values[key]))
			if new ~= nil then
				values[key] = ProfileData.copy(new)
			end
			return true, values[key]
		end,
	}
end

local function dataStore(): ProfileCore.Store?
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		warn("[robgame] profiles: DataStore unavailable: " .. tostring(store))
		return nil
	end
	local ds = store :: DataStore
	return {
		update = function(key: string, transform: (any) -> any?, userId: number): (boolean, any)
			local success, result = pcall(function()
				return ds:UpdateAsync(key, function(old: any)
					local new = transform(old)
					if new == nil then
						return nil
					end
					-- Kullanıcı kimliği anahtara etiketlenir (Roblox veri silme talepleri için).
					return new, { userId }
				end)
			end)
			if not success then
				warn("[robgame] profiles: UpdateAsync failed: " .. tostring(result))
			end
			return success, result
		end,
	}
end

local function key(player: Player): string
	return "p_" .. player.UserId
end

local function getSession(): ProfileCore.Session
	if session == nil then
		local store: ProfileCore.Store? = nil
		if game.PlaceId ~= 0 then
			store = dataStore()
		end
		if store == nil then
			if not RunService:IsStudio() and game.PlaceId ~= 0 then
				-- Canlıda bellek yedeği yok: her yükleme "error" döner, profil "failed" kalır.
				store = {
					update = function()
						return false, nil
					end,
				}
			else
				warn("[robgame] profiles: in-memory store (unpublished place / Studio)")
				store = memoryStore()
			end
		end
		session =
			ProfileCore.new(store :: ProfileCore.Store, os.time, HttpService:GenerateGUID(false))
	end
	return session :: ProfileCore.Session
end

local function load(player: Player)
	local entry: Entry = { state = "loading", profile = nil }
	entries[player] = entry
	for attempt = 1, LOAD_ATTEMPTS do
		local result, profile = ProfileCore.load(getSession(), key(player), player.UserId)
		if entries[player] ~= entry then
			-- Oyuncu yükleme sırasında çıktı: aldığımız kilidi hemen bırak.
			if result == "ok" and profile then
				ProfileCore.save(getSession(), key(player), player.UserId, profile, true)
			end
			return
		end
		if result == "ok" then
			entry.state = "ready"
			entry.profile = profile
			changedEvent:Fire(player)
			return
		end
		warn(
			string.format(
				"[robgame] profiles: load %s for %d (attempt %d)",
				result,
				player.UserId,
				attempt
			)
		)
		if attempt < LOAD_ATTEMPTS then
			task.wait(LOAD_RETRY_SECONDS)
		end
	end
	if entries[player] == entry then
		entry.state = "failed"
		changedEvent:Fire(player)
	end
end

local function save(player: Player, entry: Entry, release: boolean): ProfileCore.SaveResult?
	local profile = entry.profile
	if entry.state ~= "ready" or profile == nil then
		return nil
	end
	local result: ProfileCore.SaveResult =
		ProfileCore.save(getSession(), key(player), player.UserId, profile, release)
	if result == "lost" then
		warn("[robgame] profiles: lock lost for " .. player.UserId)
		entry.state = "lost"
		entry.profile = nil
		changedEvent:Fire(player)
	end
	return result
end

-- Hazır profil (salt okunur kullan; değiştirmek için `mutate`).
function Profiles.get(player: Player): ProfileData.Profile?
	local entry = entries[player]
	return if entry and entry.state == "ready" then entry.profile else nil
end

function Profiles.state(player: Player): State?
	local entry = entries[player]
	return if entry then entry.state else nil
end

-- Profili değiştir (yalnız hazırsa). Kayıt bir sonraki otomatik kayıtta; hemen kaydetmek için
-- `saveNow` (satın alma teslimi).
function Profiles.mutate(player: Player, fn: (ProfileData.Profile) -> ()): boolean
	local profile = Profiles.get(player)
	if profile == nil then
		return false
	end
	fn(profile)
	changedEvent:Fire(player)
	return true
end

function Profiles.saveNow(player: Player): ProfileCore.SaveResult?
	local entry = entries[player]
	if entry == nil then
		return nil
	end
	return save(player, entry, false)
end

-- Oyuncu çıkarken, profil kaydedilip kilit bırakılmadan hemen önce çağrılır.
function Profiles.onBeforeRelease(hook: (Player) -> ())
	table.insert(beforeRelease, hook)
end

function Profiles.start()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(load, player)
	end)
	for _, player in Players:GetPlayers() do
		if entries[player] == nil then
			task.spawn(load, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		-- Çıkışta son ödüller (hayat ödülü) kayıttan önce işlensin.
		for _, hook in beforeRelease do
			hook(player)
		end
		local entry = entries[player]
		entries[player] = nil
		if entry then
			save(player, entry, true)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(ProfileCore.SAVE_INTERVAL)
			for player, entry in entries do
				task.spawn(save, player, entry, false)
			end
		end
	end)
	game:BindToClose(function()
		local pending = 0
		for player, entry in entries do
			pending += 1
			task.spawn(function()
				save(player, entry, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + CLOSE_TIMEOUT
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return Profiles
