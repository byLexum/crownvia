--!strict
-- Ölüm ekranı. Kiomet'te karşılığı client/src/ui/game_ui.rs `SpawnOverlay` + `death_reason`
-- (phrases.rs). Metinler bize ait.
--
-- Doğuş isteği akışı: Hazır → İstek gönderildi (bekleme) → Başarılı (`Hello`, ekran kapanır) /
-- Başarısız (`SpawnFailed`) / Zaman aşımı → "Try again". Ekran sunucu cevabından önce kapanmaz;
-- istek hız sınırına takılsa ya da başarısız olsa da oyuncu yeniden deneyebilir.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hype = require(script.Parent.Hype)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Strings = require(script.Parent.Strings)
local Theme = require(script.Parent.Theme)

local Sim = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim")
local Unit = require(Sim.Unit)
local Rewards = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Account"):WaitForChild("Rewards")
)

export type DeathReason = { alias: string?, unit: number }
export type LifeSummary = {
	score: number,
	credits: number,
	towers: number,
	kings: number,
	best: number,
	cutoff: number?,
	seconds: number?,
	nemesis: string?,
	doubled: boolean,
}

export type Actions = {
	store: () -> (),
	friends: () -> (),
	rankings: () -> (),
	-- Sıradaki hedef metni (hesap verisi `AccountView`de).
	nextGoal: () -> string?,
}

local DeathScreen = {}

local TITLE = "YOUR KING HAS FALLEN"

local gui: ScreenGui? = nil
local reasonLabel: TextLabel? = nil
local titleLabel: TextLabel? = nil
local respawnButton: Kit.Button? = nil
local rewardRow: Frame? = nil
local scoreLabel: TextLabel? = nil
local creditsLabel: TextLabel? = nil
local towersLabel: TextLabel? = nil
local kingsLabel: TextLabel? = nil
local goalLabel: TextLabel? = nil
local nearLabel: TextLabel? = nil
local goalText: (() -> string?)? = nil
local requestSpawn: (() -> ())? = nil
local lastDeath: DeathReason? = nil

-- Cevap gelmezse bu süre sonra yeniden deneme sunulur (sn).
local SPAWN_TIMEOUT = 8

local waiting = false
-- Her istek yeni bir numara alır; eski zaman aşımı yeni isteği bozmaz.
local attempt = 0

-- Sunucunun kısa kodu → oyuncuya metin (Metinler: Codex METINLER_TR_EN.json, bize ait).
local ERRORS: { [string]: string } = {
	RATE_LIMITED = "Wait a moment and try again.",
	SPAWN_FAILED = "Couldn't join the world. Try again.",
	TIMEOUT = "No response yet. Try again.",
}

local function stat(parent: Instance, order: number, icon: string, title: string): TextLabel
	local box = Kit.well(parent, UDim2.new(0.5, -5, 1, 0), order)
	Kit.padding(box, 0, 12, 0, 12)
	Kit.list(box, { horizontal = true, gap = 10, alignY = Enum.VerticalAlignment.Center })
	Kit.icon(box, icon, 46, 1)
	local texts = Kit.box(box, UDim2.new(1, -56, 1, 0), 2)
	Kit.list(texts, { alignY = Enum.VerticalAlignment.Center })
	local value = Kit.text(texts, "0", "heading", nil, UDim2.new(1, 0, 0, 30), 1)
	Kit.text(texts, title, "small", Theme.colors.muted, UDim2.new(1, 0, 0, 22), 2)
	return value
end

local function build(onRespawn: () -> (), actions: Actions): ScreenGui
	local screen = Kit.screen("DeathScreen", 40, true)
	screen.Enabled = false

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Theme.colors.background
	dim.BackgroundTransparency = 0.35
	dim.BorderSizePixel = 0
	dim.Parent = screen

	local panel = Kit.panel(screen, UDim2.fromOffset(600, 0), false, 20)
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	Kit.scaled(panel)
	Kit.padding(panel, 22)
	Kit.list(panel, { gap = 12, alignX = Enum.HorizontalAlignment.Center })

	local title = Kit.text(panel, TITLE, "title", Theme.colors.text, UDim2.new(1, 0, 0, 40), 1)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextWrapped = false
	local reason = Kit.text(panel, "", "body", Theme.colors.muted, UDim2.fromScale(1, 0), 2)
	reason.AutomaticSize = Enum.AutomaticSize.Y
	reason.TextXAlignment = Enum.TextXAlignment.Center

	-- Maç özeti: skor, Credits, kule, kral + sıradaki hedef.
	local rewards = Kit.box(panel, UDim2.fromScale(1, 0), 3)
	rewards.AutomaticSize = Enum.AutomaticSize.Y
	rewards.Visible = false
	Kit.list(rewards, { gap = 10 })
	local top = Kit.box(rewards, UDim2.new(1, 0, 0, 74), 1)
	Kit.list(top, { horizontal = true, gap = 10 })
	scoreLabel = stat(top, 1, Icons.ui.trophy, "Score")
	creditsLabel = stat(top, 2, Icons.ui.coin, "Credits earned")
	local bottom = Kit.box(rewards, UDim2.new(1, 0, 0, 74), 2)
	Kit.list(bottom, { horizontal = true, gap = 10 })
	towersLabel = stat(bottom, 1, Icons.ui.tower, Strings.statTowers)
	kingsLabel = stat(bottom, 2, Icons.crown, Strings.statKings)
	local near = Kit.text(rewards, "", "heading", Theme.colors.danger, UDim2.fromScale(1, 0), 3)
	near.AutomaticSize = Enum.AutomaticSize.Y
	near.TextXAlignment = Enum.TextXAlignment.Center
	nearLabel = near
	local goal = Kit.text(rewards, "", "label", Theme.colors.gold, UDim2.fromScale(1, 0), 4)
	goal.AutomaticSize = Enum.AutomaticSize.Y
	goal.TextXAlignment = Enum.TextXAlignment.Center
	goalLabel = goal
	goalText = actions.nextGoal
	rewardRow = rewards

	local button = Kit.button(panel, {
		variant = "gold",
		text = Strings.tryAgain,
		textSize = 26,
		size = UDim2.new(1, 0, 0, 84),
		order = 4,
		name = "Respawn",
		onClick = function()
			DeathScreen.requestSpawn()
		end,
	})

	local row = Kit.box(panel, UDim2.new(1, 0, 0, 68), 5)
	Kit.list(row, { horizontal = true, gap = 10 })
	Kit.button(row, {
		variant = "navy",
		text = "Store",
		icon = Icons.ui.store,
		iconSize = 38,
		size = UDim2.new(1 / 3, -7, 1, 0),
		order = 1,
		name = "Store",
		onClick = actions.store,
	})
	Kit.button(row, {
		variant = "navy",
		text = Strings.rankingsTitle,
		icon = Icons.ui.trophy,
		iconSize = 34,
		textSize = 17,
		size = UDim2.new(1 / 3, -7, 1, 0),
		order = 3,
		name = "Rankings",
		onClick = actions.rankings,
	})
	Kit.button(row, {
		variant = "navy",
		text = "Friends",
		icon = Icons.ui.friends,
		iconSize = 38,
		size = UDim2.new(1 / 3, -7, 1, 0),
		order = 2,
		name = "Friends",
		onClick = actions.friends,
	})

	requestSpawn = onRespawn
	reasonLabel = reason
	titleLabel = title
	respawnButton = button
	Kit.mount(screen)
	return screen
end

-- `DeathReason::RulerKilled { alias, unit }` → metin. alias nil → sahipsiz birimler (zombi).
local function reasonText(death: DeathReason?): string
	if death == nil then
		return ""
	end
	local unit = Unit.name(death.unit)
	if death.alias then
		return string.format("Killed by %s's %s", death.alias, unit)
	end
	return string.format("Killed by an unclaimed %s", unit)
end

function DeathScreen.init(onRespawn: () -> (), actions: Actions)
	gui = build(onRespawn, actions)
end

-- Ölümde "ne kadar yakındın": rekor ya da haftalık ilk 10 için kalan puan (yakın olan).
local function nearText(data: LifeSummary): string?
	if data.best > 0 and data.score > data.best then
		return string.format(Strings.newBestLine, data.score)
	end
	local toBest = if data.best > 0 then data.best - data.score + 1 else nil
	local cutoff = data.cutoff
	local toTop = if cutoff and cutoff >= data.score then cutoff - data.score + 1 else nil
	local lines = {}
	if toTop and (toBest == nil or toTop <= toBest) then
		table.insert(lines, string.format(Strings.nearTop, toTop))
	elseif toBest then
		table.insert(lines, string.format(Strings.nearBest, toBest))
	end
	if data.nemesis then
		table.insert(
			lines,
			string.format(Strings.nemesisHint, data.nemesis, Rewards.REVENGE_REWARD)
		)
	end
	if data.doubled then
		table.insert(lines, Strings.doubledHint)
	end
	return if #lines > 0 then table.concat(lines, "\n") else nil
end

local function setButton(text: string, enabled: boolean)
	local button = respawnButton
	if button then
		button.setText(text)
		button.setEnabled(enabled)
	end
end

local function setTexts(title: string, reason: string)
	if titleLabel then
		titleLabel.Text = title
	end
	if reasonLabel then
		reasonLabel.Text = reason
	end
end

-- Ölünce: sebep + "Play again".
function DeathScreen.show(death: DeathReason?)
	local screen = gui
	if screen == nil then
		return
	end
	lastDeath = death
	if not waiting then
		setTexts(TITLE, reasonText(death))
		setButton(Strings.tryAgain, true)
	end
	screen.Enabled = true
end

-- Hayat ödülü (hesap ilerlemesi, `docs/HESAP_MAGAZA.md`): ölümden hemen sonra gelir.
function DeathScreen.setLifeReward(data: LifeSummary)
	if scoreLabel then
		scoreLabel.Text = tostring(data.score)
	end
	if creditsLabel then
		Hype.rollNumber(creditsLabel, data.credits, "+%d")
	end
	if towersLabel then
		towersLabel.Text = tostring(data.towers)
	end
	if kingsLabel then
		kingsLabel.Text = tostring(data.kings)
	end
	if reasonLabel and data.seconds then
		local line = string.format(Strings.survived, data.seconds // 60, data.seconds % 60)
		if not string.find(reasonLabel.Text, line, 1, true) then
			reasonLabel.Text = reasonLabel.Text .. "   " .. line
		end
	end
	if nearLabel then
		local near = nearText(data)
		nearLabel.Text = near or ""
		nearLabel.Visible = near ~= nil
	end
	local text = if goalText then goalText() else nil
	if goalLabel then
		goalLabel.Text = text or ""
		goalLabel.Visible = text ~= nil
	end
	if rewardRow then
		rewardRow.Visible = true
	end
end

-- Doğuş isteği gönder ve cevabı bekle. Oyun başında ekran görünmeden de çağrılır.
function DeathScreen.requestSpawn()
	if waiting then
		return
	end
	local send = requestSpawn
	if send == nil then
		return
	end
	waiting = true
	attempt += 1
	local thisAttempt = attempt
	setButton("JOINING...", false)
	send()
	task.delay(SPAWN_TIMEOUT, function()
		if waiting and attempt == thisAttempt then
			DeathScreen.spawnFailed("TIMEOUT")
		end
	end)
end

-- Sunucu `SpawnFailed` ya da zaman aşımı: ekran açılır (oyun başındaysa da), yeniden dene sunulur.
function DeathScreen.spawnFailed(reason: string)
	-- Beklenen bir istek yoksa (ör. hayattayken gelen eski cevap) ekran açılmaz.
	if not waiting then
		return
	end
	waiting = false
	local screen = gui
	if screen == nil then
		return
	end
	local message = ERRORS[reason] or ERRORS.SPAWN_FAILED
	if lastDeath ~= nil then
		setTexts(TITLE, reasonText(lastDeath) .. "\n" .. message)
	else
		setTexts("COULDN'T JOIN", message)
	end
	setButton("TRY AGAIN", true)
	screen.Enabled = true
end

-- `Hello` geldi: doğuş başarılı, ekran kapanır.
function DeathScreen.hide()
	waiting = false
	lastDeath = nil
	if rewardRow then
		rewardRow.Visible = false
	end
	if gui then
		gui.Enabled = false
	end
end

return DeathScreen
