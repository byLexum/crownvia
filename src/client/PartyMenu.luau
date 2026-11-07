--!strict
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: client/src/yew_ui/dialog/play_with_friends_dialog.rs (tag 0.1.1)

-- Parti paneli. kodiak "Play with friends" diyaloğunun karşılığı: bot sayısı seç (0..8, varsayılan 4)
-- → kendi parti sunucuna geç; arkadaş davet et; davetle gelince partiye katıl. Metinler bize ait.
-- Akış: Hazır → İstek (bekleme) → Işınlanıyor / Başarısız (sebep + "Try again" / "Back").
-- Işınlama gerçekleşmezse zaman aşımıyla aynı ekrana döner; oyuncu boş ekranda kalmaz.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")
local TeleportService = game:GetService("TeleportService")

local PartyRules = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Party"):WaitForChild("PartyRules")
)

local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

local PartyMenu = {}

export type Send = (message: { [string]: any }) -> ()

type View = "closed" | "setup" | "room" | "busy" | "failed"

-- Sunucu "working" sonrası cevap vermezse (sn). Sunucu kalabalıkta 15 sn bekleyip yeniden dener.
local WORKING_TIMEOUT = 45
-- Işınlama başladı ama oyuncu hâlâ burada (sn).
local TELEPORT_TIMEOUT = 25

-- Sunucunun kısa kodu → metin. Yeniden denenebilir olanlar "Try again" gösterir.
local MESSAGES: { [string]: string } = {
	RATE_LIMITED = "Wait a moment and try again.",
	BUSY = "Still working on your last request.",
	INVALID_BOTS = "Choose between 0 and 8 bots.",
	INVALID_DIFFICULTY = "Choose a difficulty.",
	WORLD_GONE = "This world is no longer available.",
	NOT_FOUNDER = "Only the party host can change this.",
	NOT_IN_PARTY = "You're not in a party.",
	NO_INVITE = "No invite to join.",
	PARTY_NOT_FOUND = "This invite is no longer valid.",
	PARTY_EXPIRED = "This party has expired.",
	PARTY_CLOSED = "This party has closed.",
	SERVICE_UNAVAILABLE = "Can't start right now. Try again.",
	TELEPORT_FAILED = "Teleport failed. Try again.",
	TELEPORT_FLOODED = "Too many requests. Try again shortly.",
	TIMEOUT = "No response yet. Try again.",
	INVITE_UNAVAILABLE = "Invites aren't available right now.",
}
local RETRYABLE: { [string]: boolean } = {
	RATE_LIMITED = true,
	BUSY = true,
	SERVICE_UNAVAILABLE = true,
	TELEPORT_FAILED = true,
	TELEPORT_FLOODED = true,
	TIMEOUT = true,
}
local WORKING_TEXT: { [string]: string } = {
	Create = "Starting your party...",
	Solo = "Starting your world...",
	World = "Joining world...",
	Join = "Joining your friend's party...",
	Leave = "Returning to the public world...",
}

local send: Send = function(_message: { [string]: any }) end
local view: View = "closed"
local bots = PartyRules.DEFAULT_BOTS
local inviteOnCreate = false
-- Son Play Solo zorluğu ve seçilen dünya (yeniden deneme için).
local soloDifficulty: string? = nil
local worldId: string? = nil
-- Play Solo'dan gelindi: varınca doğrudan doğ.
local autoPlay = false
-- Parti sunucusundaysak dolu.
local partyId: string? = nil
local isFounder = false
local lastAction: string? = nil
-- Son hata kodu (yeniden denenebilir mi).
local failedReason: string? = nil
-- Her istek yeni numara; eski zaman aşımı yeni isteği bozmaz.
local attempt = 0
-- Işınlama verisi "invite" → varınca davet penceresi bir kez açılır.
local pendingInvitePrompt = false

local modal: Kit.Modal? = nil
local titleLabel: TextLabel? = nil
local messageLabel: TextLabel? = nil
local botsRow: Frame? = nil
local botsLabel: TextLabel? = nil
local minusButton: Kit.Button? = nil
local plusButton: Kit.Button? = nil
local buttons: { Kit.Button } = {}

-- Alt düğme satırı: her görünümde yeniden kurulur (en fazla 3 düğme). İlki ana eylem.
local actionsRow: Frame? = nil

local function setActions(list: { { text: string, run: () -> () } })
	for _, b in buttons do
		b.root:Destroy()
	end
	table.clear(buttons)
	local row = actionsRow :: Frame
	local gap = (#list - 1) * 10
	for i, entry in list do
		local b = Kit.button(row, {
			variant = if i == 1 then "gold" else "navy",
			text = entry.text,
			textSize = 19,
			size = UDim2.new(1 / math.max(#list, 1), -math.ceil(gap / #list), 1, 0),
			order = i,
			name = "Action" .. i,
			onClick = entry.run,
		})
		table.insert(buttons, b)
	end
end

local render: () -> ()

local function close()
	view = "closed"
	render()
end

local function sendAction(action: string, message: { [string]: any })
	lastAction = action
	view = "busy"
	attempt += 1
	local thisAttempt = attempt
	if messageLabel then
		messageLabel.Text = WORKING_TEXT[action] or ""
	end
	render()
	send(message)
	task.delay(WORKING_TIMEOUT, function()
		if view == "busy" and attempt == thisAttempt then
			PartyMenu.status({ action = action, stage = "failed", reason = "TIMEOUT" })
		end
	end)
end

local function retry()
	if lastAction == "World" then
		sendAction("World", { kind = "WorldJoin", id = worldId })
	elseif lastAction == "Solo" then
		sendAction("Solo", { kind = "PartyCreate", difficulty = soloDifficulty, invite = false })
	elseif lastAction == "Create" then
		sendAction("Create", { kind = "PartyCreate", bots = bots, invite = inviteOnCreate })
	elseif lastAction == "Join" then
		sendAction("Join", { kind = "PartyJoin" })
	elseif lastAction == "Leave" then
		sendAction("Leave", { kind = "PartyLeave" })
	else
		close()
	end
end

local function back()
	view = if partyId ~= nil then "room" else "closed"
	render()
end

-- `SocialService:PromptGameInvite` + `ExperienceInviteOptions.LaunchData` (Roblox belgesi).
-- Davet verisi yalnız parti kimliği; davetli sunucuda kayıttan doğrulanır.
local function promptInvite()
	local id = partyId
	if id == nil then
		return
	end
	local player = Players.LocalPlayer :: Player
	local ok, canInvite = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	if not ok or not canInvite then
		lastAction = nil
		PartyMenu.status({ action = "Invite", stage = "failed", reason = "INVITE_UNAVAILABLE" })
		return
	end
	local options = Instance.new("ExperienceInviteOptions")
	options.LaunchData = PartyRules.encodeLaunchData(id)
	options.PromptMessage = "Join my party!"
	local prompted, err = pcall(function()
		SocialService:PromptGameInvite(player, options)
	end)
	if not prompted then
		warn("[robgame] invite prompt failed: " .. tostring(err))
	end
end

local function changeBots(delta: number)
	local nextCount = math.clamp(bots + delta, PartyRules.MIN_BOTS, PartyRules.MAX_BOTS)
	if partyId ~= nil then
		-- Parti sunucusunda: sunucu doğrular (yalnız kurucu); sayı PartyInfo ile güncellenir.
		if isFounder and nextCount ~= bots then
			send({ kind = "PartySetBots", bots = nextCount })
		end
		return
	end
	bots = nextCount
	render()
end

local function statusTitle(): string
	if lastAction == "Join" then
		return "Party invite"
	end
	if lastAction == "World" then
		return "Public worlds"
	end
	return if lastAction == "Solo" then "Play Solo" else "Party"
end

render = function()
	local m = modal
	if m == nil then
		return
	end
	if view == "closed" then
		m.close()
		return
	end
	if not m.isOpen() then
		m.open()
	end
	local title = titleLabel :: TextLabel
	local message = messageLabel :: TextLabel
	local row = botsRow :: Frame
	local showBots = view == "setup" or view == "room"
	row.Visible = showBots
	if showBots then
		local canChange = partyId == nil or isFounder
		local label = botsLabel :: TextLabel
		label.Text = string.format("Bots: %d", bots)
		local minus = minusButton :: Kit.Button
		local plus = plusButton :: Kit.Button
		minus.setEnabled(canChange and bots > PartyRules.MIN_BOTS)
		plus.setEnabled(canChange and bots < PartyRules.MAX_BOTS)
	end
	if view == "setup" then
		title.Text = "Play with friends"
		message.Text = "Your own world with the same rules. Choose how many bots join."
		setActions({
			{
				text = "Play vs bots",
				run = function()
					inviteOnCreate = false
					sendAction("Create", { kind = "PartyCreate", bots = bots, invite = false })
				end,
			},
			{
				text = "Invite friends",
				run = function()
					inviteOnCreate = true
					sendAction("Create", { kind = "PartyCreate", bots = bots, invite = true })
				end,
			},
		})
	elseif view == "room" then
		title.Text = "Party"
		message.Text = if isFounder
			then "You host this party. Friends join with an invite."
			else "Only the host can change the bots."
		setActions({
			{ text = "Invite friends", run = promptInvite },
			{
				text = "Leave party",
				run = function()
					sendAction("Leave", { kind = "PartyLeave" })
				end,
			},
		})
	elseif view == "busy" then
		title.Text = statusTitle()
		setActions({})
	elseif view == "failed" then
		title.Text = statusTitle()
		local list = {}
		if lastAction ~= nil and failedReason ~= nil and RETRYABLE[failedReason :: string] then
			table.insert(list, { text = "Try again", run = retry })
		end
		table.insert(list, { text = "Back", run = back })
		setActions(list)
	end
end

local function build()
	local m = Kit.modal({
		name = "PartyMenu",
		title = "Party",
		icon = Icons.ui.friends,
		size = Vector2.new(640, 360),
		order = 53,
	})
	m.onClosed(function()
		-- Bekleme sırasında pencere kapanmaz: işlem bitince sonuç görünmeli.
		if view == "busy" or view == "failed" then
			task.defer(render)
		else
			view = "closed"
		end
	end)
	Kit.list(m.body, { gap = 14, alignX = Enum.HorizontalAlignment.Center })

	titleLabel = m.header:FindFirstChild("Title") :: TextLabel
	local message = Kit.text(m.body, "", "body", Theme.colors.muted, UDim2.fromScale(1, 0), 1)
	message.AutomaticSize = Enum.AutomaticSize.Y
	message.TextXAlignment = Enum.TextXAlignment.Center

	local row = Kit.well(m.body, UDim2.new(1, 0, 0, 92), 2)
	row.Name = "Bots"
	Kit.padding(row, 8, 12)
	Kit.list(row, {
		horizontal = true,
		gap = 12,
		alignX = Enum.HorizontalAlignment.Center,
		alignY = Enum.VerticalAlignment.Center,
	})
	minusButton = Kit.button(row, {
		variant = "navy",
		text = "−",
		textSize = 32,
		size = UDim2.fromOffset(84, 72),
		order = 1,
		name = "Minus",
		onClick = function()
			changeBots(-1)
		end,
	})
	local count = Kit.text(row, "", "heading", nil, UDim2.fromOffset(200, 72), 2)
	count.TextXAlignment = Enum.TextXAlignment.Center
	plusButton = Kit.button(row, {
		variant = "navy",
		text = "+",
		textSize = 32,
		size = UDim2.fromOffset(84, 72),
		order = 3,
		name = "Plus",
		onClick = function()
			changeBots(1)
		end,
	})

	local actions = Kit.box(m.body, UDim2.new(1, 0, 0, 76), 3)
	actions.Name = "Actions"
	Kit.list(actions, { horizontal = true, gap = 10 })

	modal = m
	messageLabel = message
	botsRow = row
	botsLabel = count
	actionsRow = actions
end

-- Aç/kapa (üst sıra düğmesi, ana ekran, ölüm ekranı).
function PartyMenu.open()
	if view == "closed" then
		view = if partyId ~= nil then "room" else "setup"
		render()
	end
end

function PartyMenu.init(sendMessage: Send)
	send = sendMessage
	build()
	local ok, data = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)
	pendingInvitePrompt = ok and type(data) == "table" and (data :: any).invite == true
	autoPlay = ok and type(data) == "table" and (data :: any).autoPlay == true
	render()
end

-- Play Solo: seçilen zorlukla kendi dünyasını kur. Bekleme/hata akışı parti ile aynı.
function PartyMenu.startSolo(difficulty: string)
	soloDifficulty = difficulty
	sendAction("Solo", { kind = "PartyCreate", difficulty = difficulty, invite = false })
end

-- Genel sunucu listesinden başka bir dünyaya geç.
function PartyMenu.joinWorld(id: string)
	worldId = id
	sendAction("World", { kind = "WorldJoin", id = id })
end

-- Oyuncu Play Solo ile mi geldi (ana ekranda ikinci kez Play'e basmasın).
function PartyMenu.shouldAutoPlay(): boolean
	return autoPlay
end

-- Sunucu `PartyInfo`: parti sunucusundaysak oda bilgisi.
function PartyMenu.info(message: { [string]: any })
	if type(message.partyId) ~= "string" then
		return
	end
	partyId = message.partyId
	isFounder = message.founder == true
	if type(message.bots) == "number" then
		bots = message.bots
	end
	if view == "setup" then
		view = "room"
	end
	if pendingInvitePrompt then
		pendingInvitePrompt = false
		view = "room"
		render()
		promptInvite()
		return
	end
	render()
end

-- Sunucu `PartyStatus { action, stage, reason }`.
function PartyMenu.status(message: { [string]: any })
	local action = message.action
	local stage = message.stage
	if type(action) ~= "string" or type(stage) ~= "string" then
		return
	end
	if stage == "working" then
		-- Sunucu davetle gelen oyuncuyu kendiliğinden partisine götürüyor.
		if view ~= "busy" or lastAction ~= action then
			lastAction = action
			view = "busy"
			if messageLabel then
				messageLabel.Text = WORKING_TEXT[action] or ""
			end
			render()
		end
		return
	end
	if stage == "teleporting" then
		lastAction = action
		view = "busy"
		attempt += 1
		local thisAttempt = attempt
		if messageLabel then
			messageLabel.Text = "Teleporting..."
		end
		render()
		task.delay(TELEPORT_TIMEOUT, function()
			if view == "busy" and attempt == thisAttempt then
				PartyMenu.status({ action = action, stage = "failed", reason = "TIMEOUT" })
			end
		end)
		return
	end
	if stage == "failed" then
		local reason = if type(message.reason) == "string"
			then message.reason
			else "TELEPORT_FAILED"
		if action == "SetBots" or action == "Invite" then
			-- Küçük hata: panel açık kalır, mesaj gösterilir.
			lastAction = nil
		else
			lastAction = action
		end
		attempt += 1
		failedReason = reason
		view = "failed"
		if messageLabel then
			messageLabel.Text = MESSAGES[reason] or MESSAGES.TELEPORT_FAILED
		end
		render()
	end
end

return PartyMenu
