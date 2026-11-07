--!strict
-- Ayarlar: müzik ve efekt sesi (aç/kapa + ses düzeyi), düşük grafik, nasıl oynanır, Licenses sayfası.
-- Licenses: telif notu + kaynak kod linki (AGPL madde 13, proje kararı 2026-11-06). Oyun yayındayken
-- repo public olmalı ve yayındaki sürümü içermeli (CLAUDE.md "Lisans").

local AccountView = require(script.Parent.AccountView)
local Audio = require(script.Parent.Audio)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Territory = require(script.Parent.Territory)
local Theme = require(script.Parent.Theme)

local Settings = {}

local LICENSE_TEXT =
	"CROWNVIA contains code © Softbear, Inc., licensed under the GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later), and code © Softbear, Inc. licensed under LGPL-3.0-or-later."

local SOURCE_URL = "github.com/byLexum/crownvia"

local state = {
	-- 2026-11-06 geliştirici: yeni müziklerle varsayılan açık (ayarlardan kapatılabilir).
	music = true,
	sfx = true,
	musicVolume = 1,
	sfxVolume = 1,
	lowGraphics = false,
}

local main: Kit.Modal? = nil
local onHelp: (() -> ())? = nil
local onReplay: (() -> ())? = nil

local function save()
	AccountView.setAudio(state.music, state.sfx, state.musicVolume, state.sfxVolume)
end

-- Etiket + (varsa) kaydırıcı + sağda anahtar. `slider` nil ise yalnız etiket ve anahtar.
local function row(
	parent: Instance,
	order: number,
	label: string,
	get: () -> boolean,
	set: (boolean) -> (),
	slider: {
		get: () -> number,
		set: (number) -> (),
		release: () -> (),
	}?
): () -> ()
	local box = Kit.well(parent, UDim2.new(1, 0, 0, 72), order)
	Kit.padding(box, 0, 14, 0, 18)
	local title = Kit.text(
		box,
		label,
		"label",
		nil,
		if slider then UDim2.new(0, 150, 1, 0) else UDim2.new(1, -90, 1, 0)
	)
	title.TextWrapped = false
	local toggle, refresh = Kit.toggle(box, get, set)
	toggle.AnchorPoint = Vector2.new(1, 0.5)
	toggle.Position = UDim2.fromScale(1, 0.5)
	if slider then
		local control =
			Kit.slider(box, UDim2.new(1, -290, 0, 40), slider.get, slider.set, slider.release)
		control.AnchorPoint = Vector2.new(0, 0.5)
		control.Position = UDim2.new(0, 166, 0.5, 0)
	end
	return refresh
end

function Settings.init(help: () -> (), replayTutorial: () -> ())
	if main ~= nil then
		return
	end
	onHelp = help
	onReplay = replayTutorial
	-- Müzik tercihi profille gelince uygulanır (`applySaved`); öncesinde Audio sessiz bekler.

	local modal = Kit.modal({
		name = "Settings",
		title = Strings.settingsTitle,
		icon = Icons.ui.gear,
		size = Vector2.new(560, 520),
	})
	local licenses = Kit.modal({
		name = "Licenses",
		title = Strings.licensesTitle,
		size = Vector2.new(640, 330),
		order = 51,
	})

	local list = Kit.scroll(modal.body, UDim2.fromScale(1, 1), 10)
	local refreshMusic = row(list, 1, Strings.music, function()
		return state.music
	end, function(on)
		state.music = on
		Audio.setMusicEnabled(on)
		save()
	end, {
		get = function()
			return state.musicVolume
		end,
		set = function(value)
			state.musicVolume = value
			Audio.setMusicLevel(value)
		end,
		release = save,
	})
	local refreshSfx = row(list, 2, Strings.soundEffects, function()
		return state.sfx
	end, function(on)
		state.sfx = on
		Audio.setSfxEnabled(on)
		save()
	end, {
		get = function()
			return state.sfxVolume
		end,
		set = function(value)
			state.sfxVolume = value
			Audio.setSfxLevel(value)
		end,
		release = function()
			Audio.play("click")
			save()
		end,
	})
	local refreshGraphics = row(list, 3, Strings.lowGraphics, function()
		return state.lowGraphics
	end, function(on)
		state.lowGraphics = on
		Territory.setLowGraphics(on)
		AccountView.setGraphics(on)
	end, nil)
	-- Kayıtlı tercih profille gelir; oturumda bir kez uygulanır (sonraki değişiklikler buradan gider).
	local applied = false
	local function applySaved()
		local profile = AccountView.profile()
		local audio = profile and profile.audio
		if applied or profile == nil or audio == nil then
			return
		end
		applied = true
		state.music = audio.music
		state.sfx = audio.sfx
		state.musicVolume = audio.musicVolume or 1
		state.sfxVolume = audio.sfxVolume or 1
		state.lowGraphics = profile.lowGraphics
		Audio.setMusicLevel(state.musicVolume)
		Audio.setSfxLevel(state.sfxVolume)
		Audio.setMusicEnabled(state.music)
		Audio.setSfxEnabled(state.sfx)
		Territory.setLowGraphics(state.lowGraphics)
		refreshMusic()
		refreshSfx()
		refreshGraphics()
	end
	AccountView.onProfileChanged(applySaved)
	applySaved()
	Kit.button(list, {
		variant = "navy",
		text = Strings.howToPlay,
		icon = Icons.ui.help,
		iconSize = 34,
		size = UDim2.new(1, 0, 0, 68),
		order = 4,
		name = "Help",
		onClick = function()
			modal.close()
			local run = onHelp
			if run then
				run()
			end
		end,
	})
	Kit.button(list, {
		variant = "navy",
		text = Strings.replayTutorial,
		size = UDim2.new(1, 0, 0, 60),
		order = 5,
		name = "ReplayTutorial",
		onClick = function()
			modal.close()
			AccountView.setTutorialDone(false)
			local run = onReplay
			if run then
				run()
			end
		end,
	})
	local licenseButton = Instance.new("TextButton")
	licenseButton.Name = "Licenses"
	licenseButton.BackgroundTransparency = 1
	licenseButton.FontFace = Theme.fonts.strong
	licenseButton.TextColor3 = Theme.colors.muted
	licenseButton.TextSize = 17
	licenseButton.Text = Strings.licensesTitle
	licenseButton.Size = UDim2.new(1, 0, 0, 44)
	licenseButton.LayoutOrder = 6
	licenseButton.Parent = list
	licenseButton.Activated:Connect(function()
		Audio.play("click")
		licenses.open()
	end)

	Kit.list(licenses.body, { gap = 12 })
	Kit.paragraph(licenses.body, LICENSE_TEXT, "body", Theme.colors.muted).LayoutOrder = 1
	Kit.text(licenses.body, Strings.sourceCode, "label", nil, nil, 2)
	-- Roblox dış link açmaz: metin seçilip kopyalanabilsin diye salt okunur kutu.
	local link = Instance.new("TextBox")
	link.Name = "SourceLink"
	link.BackgroundColor3 = Theme.colors.well
	link.BorderSizePixel = 0
	link.ClearTextOnFocus = false
	link.TextEditable = false
	link.FontFace = Theme.fonts.strong
	link.TextColor3 = Theme.colors.gold
	link.TextSize = 20
	link.Text = SOURCE_URL
	link.Size = UDim2.new(1, 0, 0, 56)
	link.LayoutOrder = 3
	Kit.corner(link, 12)
	link.Parent = licenses.body

	main = modal
end

function Settings.open()
	local modal = main
	if modal then
		modal.open()
	end
end

return Settings
