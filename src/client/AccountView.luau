--!strict
-- Hesap ilerlemesi istemci tarafı (Kiomet'te yok; `docs/HESAP_MAGAZA.md`): sunucudan gelen son
-- profil (Credits, günlük hedefler, envanter) ve ödül bildirimleri.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Account = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Account")
local Catalog = require(Account:WaitForChild("Catalog"))
local Products = require(Account:WaitForChild("Products"))

local Audio = require(script.Parent.Audio)
local Cosmetics = require(script.Parent.Cosmetics)
local DeathScreen = require(script.Parent.DeathScreen)
local Hype = require(script.Parent.Hype)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)

local AccountView = {}

export type Goal = { kind: string, target: number, progress: number, done: boolean }
export type Profile = {
	state: string?,
	credits: number,
	owned: { [string]: boolean },
	-- Sahip olunan Game Pass anahtarları (sahipliği Roblox tutar).
	passes: { [string]: boolean },
	equipped: { [string]: string },
	goals: { Goal },
	captures: number,
	frameCaptures: number,
	audio: { music: boolean, sfx: boolean, musicVolume: number?, sfxVolume: number? }?,
	lowGraphics: boolean,
	minutes: number,
	activeMinutes: number,
	oncePacks: { [string]: boolean },
	achievements: { [string]: boolean },
	streak: number,
	tutorialDone: boolean,
	stats: { [string]: number },
}

local current: Profile? = nil
local profileListeners: { () -> () } = {}
local sendCommand: ((message: { [string]: any }) -> ())? = nil
local list: Frame? = nil
local TOAST_SECONDS = 3.5

local function ensureGui(): Frame
	if list then
		return list
	end
	-- Pencerelerin üstünde: satın alma sonucu mağaza açıkken görünsün.
	local screen = Kit.screen("RewardToast", 60)
	local frame = Kit.box(screen, UDim2.fromOffset(460, 0))
	frame.Name = "List"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, 72)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	Kit.scaled(frame)
	Kit.list(frame, { gap = 6, alignX = Enum.HorizontalAlignment.Center })
	Kit.mount(screen)
	list = frame
	return frame
end

local order = 0
local function toast(text: string, icon: string?)
	local parent = ensureGui()
	order += 1
	local box = Kit.panel(parent, UDim2.new(1, 0, 0, 60), false, 14)
	box.LayoutOrder = order
	Kit.padding(box, 0, 14, 0, 10)
	Kit.list(box, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })
	Kit.icon(box, icon or Icons.ui.check, 40, 1)
	local label = Kit.text(box, text, "label", nil, UDim2.new(1, -50, 1, 0), 2)
	label.TextWrapped = false
	label.TextTruncate = Enum.TextTruncate.AtEnd
	task.delay(TOAST_SECONDS, function()
		box:Destroy()
	end)
end

local function itemName(id: string): string
	return Strings.itemNames[id] or id
end

-- `Profile` mesajı.
function AccountView.applyProfile(message: any)
	if type(message.credits) ~= "number" then
		current = nil
		for _, listener in profileListeners do
			listener()
		end
		return
	end
	current = {
		state = message.state,
		credits = message.credits,
		owned = message.owned or {},
		passes = message.passes or {},
		equipped = message.equipped or {},
		goals = message.goals or {},
		captures = message.captures or 0,
		frameCaptures = message.frameCaptures or 0,
		audio = message.audio,
		lowGraphics = message.lowGraphics == true,
		minutes = message.minutes or 0,
		activeMinutes = message.activeMinutes or 0,
		oncePacks = message.oncePacks or {},
		achievements = message.achievements or {},
		streak = tonumber(message.streak) or 0,
		tutorialDone = message.tutorialDone == true,
		stats = message.stats or {},
	}
	for _, listener in profileListeners do
		listener()
	end
end

-- Profil değişince (mağaza ekranı yenilenir).
function AccountView.onProfileChanged(listener: () -> ())
	table.insert(profileListeners, listener)
end

function AccountView.profile(): Profile?
	return current
end

-- Oyuncu bu kozmetiğe sahip mi (Credits ile alınmış, ücretsiz açılmış ya da Game Pass).
function AccountView.owns(item: Catalog.Item): boolean
	local profile = current
	if profile == nil then
		return false
	end
	return profile.owned[item.id] == true
		or (item.pass ~= nil and profile.passes[item.pass] == true)
end

function AccountView.init(send: (message: { [string]: any }) -> ())
	sendCommand = send
end

-- Ses tercihi profile yazılır (sunucu doğrular).
function AccountView.setTutorialDone(done: boolean)
	local send = sendCommand
	if send then
		send({ kind = "SetTutorialDone", done = done })
	end
end

function AccountView.setAudio(music: boolean, sfx: boolean, musicVolume: number, sfxVolume: number)
	if sendCommand then
		sendCommand({
			kind = "SetAudio",
			music = music,
			sfx = sfx,
			musicVolume = musicVolume,
			sfxVolume = sfxVolume,
		})
	end
end

function AccountView.setGraphics(low: boolean)
	if sendCommand then
		sendCommand({ kind = "SetGraphics", low = low })
	end
end

-- Credits ile satın al (sunucu doğrular; sonuç `InventoryResult`).
function AccountView.buy(itemId: string)
	if sendCommand then
		sendCommand({ kind = "BuyItem", item = itemId })
	end
end

-- Kuşan; `itemId` nil → varsayılan.
function AccountView.equip(slot: string, itemId: string?)
	if sendCommand then
		sendCommand({ kind = "EquipItem", slot = slot, item = itemId })
	end
end

-- `Cosmetics` mesajı (veri Cosmetics.luau'da; görseller onu okur).
function AccountView.applyCosmetics(message: any)
	Cosmetics.apply(message.players)
end

-- Robux istemi (teslim sunucuda: ProcessReceipt / Game Pass). Kimliği 0 olan ürün henüz yok.
function AccountView.promptCreditPack(key: string): boolean
	for _, pack in Products.CREDIT_PACKS do
		if pack.key == key and pack.productId ~= 0 then
			MarketplaceService:PromptProductPurchase(Players.LocalPlayer, pack.productId)
			return true
		end
	end
	return false
end

function AccountView.promptPass(key: string): boolean
	local pass = Products.pass(key)
	if pass and pass.passId ~= 0 then
		MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, pass.passId)
		return true
	end
	return false
end

-- `PurchaseResult` mesajı (Robux teslimi tamamlandı).
function AccountView.purchaseResult(message: any)
	if type(message.credits) == "number" then
		toast(string.format(Strings.creditsAdded, message.credits), Icons.ui.coin)
		Audio.play("click")
	elseif type(message.item) == "string" then
		toast(string.format(Strings.unlocked, itemName(message.item)))
		Audio.play("click")
	end
end

-- `InventoryResult` mesajı.
function AccountView.inventoryResult(message: any)
	local item = if type(message.item) == "string" then itemName(message.item) else ""
	if message.ok then
		if message.action == "buy" then
			toast(string.format(Strings.purchased, item))
		elseif item == "" then
			toast(Strings.unequipped)
		else
			toast(string.format(Strings.equipped, item))
		end
	else
		toast(
			Strings.inventoryErrors[message.error] or Strings.inventoryErrors.FAILED,
			Icons.ui.warning
		)
	end
end

-- `Reward` mesajı.
function AccountView.reward(message: any)
	local event = message.event
	if type(event) ~= "table" then
		return
	end
	if event.kind == "goal" and type(event.reward) == "number" then
		toast(string.format(Strings.goalDone, event.reward), Icons.ui.coin)
		Audio.play("click")
	elseif event.kind == "achievement" and type(event.reward) == "number" then
		toast(string.format(Strings.achievementDone, event.reward), Icons.ui.trophy)
		Audio.play("upgrade")
	elseif event.kind == "play" and type(event.reward) == "number" then
		toast(string.format(Strings.playReward, event.minutes, event.reward), Icons.ui.coin)
		Audio.play("click")
	elseif event.kind == "unlock" and type(event.item) == "string" then
		toast(string.format(Strings.unlocked, itemName(event.item)))
		Audio.play("click")
	elseif event.kind == "life" and type(event.reward) == "number" then
		DeathScreen.setLifeReward({
			score = tonumber(event.score) or 0,
			credits = event.reward,
			towers = tonumber(event.towers) or 0,
			kings = tonumber(event.kings) or 0,
			best = tonumber(event.best) or 0,
			cutoff = tonumber(event.cutoff),
			seconds = tonumber(event.seconds),
			nemesis = if type(event.nemesis) == "string" then event.nemesis else nil,
			doubled = event.doubled == true,
		})
	elseif event.kind == "streak" and type(event.reward) == "number" then
		if type(event.chest) == "number" then
			Hype.chest(tonumber(event.day) or event.count, event.reward + event.chest)
		else
			toast(string.format(Strings.streakReward, event.count, event.reward), Icons.ui.coin)
			Audio.play("upgrade")
		end
	elseif event.kind == "king" and type(event.reward) == "number" then
		Hype.kingSlain(event.reward)
	elseif event.kind == "revenge" and type(event.reward) == "number" then
		Hype.revenge(event.reward)
	elseif event.kind == "combo" and type(event.count) == "number" then
		Hype.combo(event.count, tonumber(event.reward) or 0)
	elseif event.kind == "record" and type(event.score) == "number" then
		Hype.newBest(event.score)
	end
end

return AccountView
