--!strict
-- Sesler ve müzik (ElevenLabs, Magnific üzerinden üretildi; seviyeleri eşitlendi, müzikler döngülü). Kimliği olmayan ses sessizce atlanır.
-- Ayarlar menüsü müziği ve efektleri ayrı ayrı kapatır.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Audio = {}

export type SoundName =
	"click"
	| "select"
	| "deploy"
	| "capture"
	| "towerLost"
	| "upgrade"
	| "alliance"
	| "warning"
	| "shellFire"
	| "shellImpact"
	| "empLaunch"
	| "empImpact"
	| "nukeLaunch"
	| "nukeImpact"
	| "death"
	| "spawn"
	| "unitLost"
	| "kingSlain"
	| "newBest"
	| "chestOpen"

-- Roblox ses kimlikleri (byLexum, Asset Manager toplu yükleme 2026-11-06; kaynak `dist/v2/final`,
-- ortak karakter: temiz, yumruklu, oyuncak askeri). 0 = yüklenmedi.
local SOUND_IDS: { [SoundName]: number } = {
	click = 133145876720612,
	select = 96048122781487,
	deploy = 132762537986321,
	capture = 83067831923837,
	towerLost = 84791336649815,
	upgrade = 126863415189291,
	alliance = 137018937991990,
	warning = 102796818292706,
	shellFire = 127896888993071,
	shellImpact = 103572948539654,
	empLaunch = 89721004666729,
	empImpact = 70537339165979,
	nukeLaunch = 104093260971089,
	nukeImpact = 88213708725836,
	death = 116159911033905,
	spawn = 135906368213112,
	unitLost = 127802241611978,
	kingSlain = 107319592457045,
	newBest = 125913904236894,
	chestOpen = 77718088303167,
}

-- Kimliği henüz girilmemiş ödül seslerinin yerine çalan ses.
local FALLBACK: { [string]: SoundName } = {
	kingSlain = "upgrade",
	newBest = "upgrade",
	chestOpen = "capture",
}

-- Kral saldırı altındayken döngüde çalar. 0 = henüz yüklenmedi (kaynak `dist/v2/final`).
local HEARTBEAT_ID = 100302717789249
local HEARTBEAT_VOLUME = 0.8

local VOLUME: { [SoundName]: number } = {
	click = 0.4,
	select = 0.35,
	nukeImpact = 0.9,
}

local MUSIC_IDS = {
	menu = 133857376725739,
	game = 122061725555018,
}

-- Müzik grubu ses düzeyi (efektlerin altında kalsın ama duyulsun).
local MUSIC_VOLUME = 0.6

-- Müzik tercihi profille gelir (kapatılmış olabilir): gelene kadar grup sessiz kalır, gelince
-- yumuşakça açılır. Önceden müzik tercih gelmeden çalıp kesiliyordu. Profil gelmezse (ağ/veri
-- hatası) PREF_WAIT sonunda varsayılan: açık.
local MUSIC_FADE_IN = 1.5
local MUSIC_FADE = 0.3
local PREF_WAIT = 5

local SFX_VOLUME = 0.8

local musicState: "pending" | boolean = "pending"
-- Oyuncunun kaydırıcı düzeyleri (profille gelir); aç/kapa anahtarından bağımsız.
local musicLevel = 1
local sfxLevel = 1
local sfxOn = true
local sfxGroup: SoundGroup? = nil
local musicGroup: SoundGroup? = nil
local sounds: { [SoundName]: Sound } = {}
local music: Sound? = nil
local musicTrack: string? = nil

local function groups(): (SoundGroup, SoundGroup)
	if sfxGroup == nil or musicGroup == nil then
		local sfx = Instance.new("SoundGroup")
		sfx.Name = "CrownviaSfx"
		sfx.Volume = if sfxOn then SFX_VOLUME * sfxLevel else 0
		sfx.Parent = SoundService
		local mus = Instance.new("SoundGroup")
		mus.Name = "CrownviaMusic"
		-- Tercih gelene kadar sessiz (`musicState`); gelmiş ve açıksa tam ses.
		mus.Volume = if musicState == true then MUSIC_VOLUME * musicLevel else 0
		mus.Parent = SoundService
		sfxGroup, musicGroup = sfx, mus
	end
	return sfxGroup :: SoundGroup, musicGroup :: SoundGroup
end

local speedOverride = 1

function Audio.play(name: SoundName)
	local id = SOUND_IDS[name]
	if id == 0 then
		local fallback = FALLBACK[name]
		if fallback then
			Audio.play(fallback :: any)
		end
		return
	end
	local sound: Sound? = sounds[name]
	if sound == nil then
		local sfx = groups()
		local s = Instance.new("Sound")
		s.Name = name
		s.SoundId = "rbxassetid://" .. id
		s.Volume = VOLUME[name] or 0.6
		s.SoundGroup = sfx
		s.Parent = sfx
		sounds[name] = s
		sound = s
	end
	local s = sound :: Sound
	s.PlaybackSpeed = speedOverride
	speedOverride = 1
	SoundService:PlayLocalSound(s)
end

-- Sesi farklı perdede çal (fetih serisi, sayı döndürme).
function Audio.playPitched(name: SoundName, speed: number)
	speedOverride = speed
	Audio.play(name)
	speedOverride = 1
end

-- Dünya sesleri (fetih, füze, isabet): menü arkasında izlerken susar.
local worldMuted = false

function Audio.setWorldMuted(muted: boolean)
	worldMuted = muted
end

function Audio.world(name: SoundName)
	if not worldMuted then
		Audio.play(name)
	end
end

local heartbeat: Sound? = nil

-- Kral saldırı altında: kalp atışı.
function Audio.setHeartbeat(on: boolean)
	if HEARTBEAT_ID == 0 then
		return
	end
	local sound = heartbeat
	if sound == nil then
		if not on then
			return
		end
		local sfx = groups()
		local s = Instance.new("Sound")
		s.Name = "Heartbeat"
		s.SoundId = "rbxassetid://" .. HEARTBEAT_ID
		s.Volume = HEARTBEAT_VOLUME
		s.Looped = true
		s.SoundGroup = sfx
		s.Parent = sfx
		heartbeat = s
		sound = s
	end
	local s = sound :: Sound
	if on and not s.IsPlaying then
		s:Play()
	elseif not on and s.IsPlaying then
		s:Stop()
	end
end

-- Dünya sesi, konuma göre kısılır (game.rs `volume`: kameranın baktığı noktaya uzaklık).
function Audio.worldAt(name: SoundName, position: Vector3)
	if worldMuted or SOUND_IDS[name] == 0 then
		return
	end
	local camera = workspace.CurrentCamera.CFrame
	local look = camera.LookVector
	local focus = camera.Position + look * (camera.Position.Y / math.max(-look.Y, 0.1))
	local distance = (Vector3.new(position.X, 0, position.Z) - Vector3.new(focus.X, 0, focus.Z)).Magnitude
	Audio.play(name)
	local sound = sounds[name]
	if sound then
		local base = VOLUME[name] or 0.6
		sound.Volume = base * math.clamp(1 / (1 + distance / 60), 0.25, 1)
	end
end

-- "menu" ya da "game"; aynı parça çalıyorsa dokunmaz.
function Audio.music(track: "menu" | "game")
	if musicTrack == track then
		return
	end
	musicTrack = track
	if musicState == "pending" then
		task.delay(PREF_WAIT, function()
			if musicState == "pending" then
				Audio.setMusicEnabled(true)
			end
		end)
	end
	if music then
		music:Destroy()
		music = nil
	end
	local id = MUSIC_IDS[track]
	if id == 0 then
		return
	end
	local _, mus = groups()
	local s = Instance.new("Sound")
	s.Name = "Music"
	s.SoundId = "rbxassetid://" .. id
	s.Looped = true
	s.Volume = 1
	s.SoundGroup = mus
	s.Parent = mus
	s:Play()
	music = s
	-- Yükleme başarısızsa (ör. Roblox incelemesi o an bitmemişti) bir kez yeniden dene.
	task.delay(8, function()
		if music == s and not s.IsLoaded then
			musicTrack = nil
			Audio.music(track)
		end
	end)
end

function Audio.setMusicEnabled(enabled: boolean)
	local _, mus = groups()
	local fade = if musicState == "pending" then MUSIC_FADE_IN else MUSIC_FADE
	musicState = enabled
	TweenService:Create(
		mus,
		TweenInfo.new(fade, Enum.EasingStyle.Sine),
		{ Volume = if enabled then MUSIC_VOLUME * musicLevel else 0 }
	):Play()
end

function Audio.setSfxEnabled(enabled: boolean)
	local sfx = groups()
	sfxOn = enabled
	sfx.Volume = if enabled then SFX_VOLUME * sfxLevel else 0
end

-- Ayarlar kaydırıcıları (0–1): açıksa grup sesi anında değişir.
function Audio.setMusicLevel(level: number)
	musicLevel = math.clamp(level, 0, 1)
	if musicState == true then
		local _, mus = groups()
		mus.Volume = MUSIC_VOLUME * musicLevel
	end
end

function Audio.setSfxLevel(level: number)
	sfxLevel = math.clamp(level, 0, 1)
	if sfxOn then
		local sfx = groups()
		sfx.Volume = SFX_VOLUME * sfxLevel
	end
end

return Audio
