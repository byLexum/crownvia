--!strict
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: client/src/yew_ui/overlay/leaderboard.rs (tag 0.1.1)

-- Canlı skor tablosu (sağ üst, ayarların altında). Kaynak: kodiak `LeaderboardOverlay`;
-- Kiomet'te yalnız hayattayken gösterilir (`liveboard={props.alive && !nexus}`).
-- İlk 10 + oyuncu ilk 10'da değilse kendi satırı ("your score").
-- Haritayı kapatmasın diye ilk 3 + oyuncunun kendi sırası görünür; başlığa dokununca kaynaktaki
-- gibi ilk 10 açılır.

local Players = game:GetService("Players")

local Cosmetics = require(script.Parent.Cosmetics)
local Icons = require(script.Parent.Icons)
local Kit = require(script.Parent.Kit)
local Nav = require(script.Parent.Nav)
local Strings = require(script.Parent.Strings)
local Hype = require(script.Parent.Hype)
local Theme = require(script.Parent.Theme)
local WorldView = require(script.Parent.WorldView)

local Leaderboard = {}

export type Entry = { id: number, alias: string, score: number, bot: boolean? }
export type Message = { top: { Entry }, you: { rank: number, score: number }? }

local ROWS = 10
local ROW_HEIGHT = 25
local COMPACT_ROWS = 3

type Row = { frame: Frame, rank: TextLabel, name: TextLabel, score: TextLabel }

local function tag(entry: Entry): string
	return if entry.bot then entry.alias .. " (BOT)" else entry.alias
end

local panel: Frame? = nil
local rows: { Row } = {}
local youRow: Row? = nil
local expanded = false

local function row(parent: Instance, order: number): Row
	local frame = Kit.box(parent, UDim2.new(1, 0, 0, ROW_HEIGHT), order)
	frame.Visible = false
	Kit.corner(frame, 8)
	local rank = Kit.text(frame, "", "label", Theme.colors.muted, UDim2.new(0, 28, 1, 0))
	rank.TextSize = 18
	local name = Kit.text(frame, "", "body", nil, UDim2.new(1, -86, 1, 0))
	name.Position = UDim2.fromOffset(28, 0)
	name.TextSize = 18
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local score = Kit.text(frame, "", "label", Theme.colors.text, UDim2.new(0, 56, 1, 0))
	score.AnchorPoint = Vector2.new(1, 0)
	score.Position = UDim2.fromScale(1, 0)
	score.TextSize = 18
	score.TextXAlignment = Enum.TextXAlignment.Right
	-- Kozmetik çerçeve (Victor Frame, docs/HESAP_MAGAZA.md): sıra numarasının arkasında defne +
	-- satırın çevresinde altın çizgi. Varsayılan kapalı.
	local laurel = Instance.new("ImageLabel")
	laurel.Name = "Laurel"
	laurel.AnchorPoint = Vector2.new(0.5, 0.5)
	laurel.Position = UDim2.fromOffset(11, ROW_HEIGHT / 2)
	laurel.Size = UDim2.fromOffset(ROW_HEIGHT + 6, ROW_HEIGHT + 6)
	laurel.BackgroundTransparency = 1
	laurel.ImageColor3 = Theme.colors.crown
	laurel.ZIndex = 0
	laurel.Visible = false
	laurel.Parent = frame
	local stroke = Kit.stroke(frame, Theme.colors.crown, 1)
	stroke.Name = "FrameStroke"
	stroke.Enabled = false
	return { frame = frame, rank = rank, name = name, score = score }
end

local lastMessage: Message? = nil
local lastRank: number? = nil

local function fill(
	r: Row,
	rank: number,
	alias: string,
	score: number,
	mine: boolean,
	simId: number?
)
	r.frame.Visible = true
	r.rank.Text = tostring(rank + 1)
	r.name.Text = alias
	r.score.Text = tostring(score)
	r.name.TextColor3 = if mine then Theme.colors.own else Theme.colors.text
	r.name.FontFace = if mine then Theme.fonts.heading else Theme.fonts.body
	local frameImage = if simId then Cosmetics.image(simId, "frame") else nil
	local laurel = r.frame:FindFirstChild("Laurel") :: ImageLabel?
	if laurel then
		laurel.Visible = frameImage ~= nil
		laurel.Image = frameImage or ""
		-- Defne dokusu beyazdır, altına boyanır; plakalar kendi renginde.
		local tinted = simId ~= nil and Cosmetics.get(simId, "frame") == "victor_frame"
		laurel.ImageColor3 = if tinted then Theme.colors.crown else Color3.new(1, 1, 1)
	end
	local stroke = r.frame:FindFirstChild("FrameStroke") :: UIStroke?
	if stroke then
		stroke.Enabled = frameImage ~= nil
	end
end

function Leaderboard.apply(message: Message)
	if panel == nil then
		return
	end
	lastMessage = message
	local me = WorldView.me()
	local mineRank: number? = nil
	local mineScore = 0
	for i, r in rows do
		local entry = message.top[i]
		if entry then
			local mine = entry.id == me
			if mine then
				mineRank, mineScore = i - 1, entry.score
			end
			-- Botlar insan gibi gösterilmez: adın yanında (BOT) (WorldView.playerLabel ile aynı kural).
			fill(r, i - 1, tag(entry), entry.score, mine, entry.id)
			r.frame.Visible = expanded or i <= COMPACT_ROWS
		else
			r.frame.Visible = false
		end
	end
	local you = message.you
	-- Sıra atlama kutlaması: yükselince geçilen oyuncunun adıyla.
	local current = mineRank or (if you then you.rank else nil)
	-- Kutlama yalnız oyundayken: ana menüde (tablo gizli, arkada bot dünyası) çıkmaz.
	if not panel.Visible then
		current = nil
	end
	if current ~= nil and lastRank ~= nil and current < lastRank then
		local passed = message.top[current + 2]
		Hype.rankUp(if passed then tag(passed) else nil, current + 1)
	end
	lastRank = current
	local yr = youRow :: Row
	local alias = Players.LocalPlayer.DisplayName
	if you and mineRank == nil then
		fill(yr, you.rank, alias, you.score, true, me)
	elseif mineRank ~= nil and not expanded and mineRank >= COMPACT_ROWS then
		fill(yr, mineRank, alias, mineScore, true, me)
	else
		yr.frame.Visible = false
	end
end

function Leaderboard.init()
	if panel ~= nil then
		return
	end
	local frame = Kit.panel(Nav.right(), UDim2.fromOffset(216, 0), true, 14)
	frame.Name = "Leaderboard"
	frame.LayoutOrder = 1
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Visible = false
	Kit.padding(frame, 6, 10)
	Kit.list(frame, { gap = 1 })

	local head = Instance.new("TextButton")
	head.Name = "Head"
	head.Text = ""
	head.BackgroundTransparency = 1
	head.Size = UDim2.new(1, 0, 0, 40)
	head.Parent = frame
	Kit.list(head, { horizontal = true, gap = 6, alignY = Enum.VerticalAlignment.Center })
	Kit.icon(head, Icons.ui.trophy, 30, 1)
	local title = Kit.text(head, Strings.leaderboard, "label", nil, UDim2.new(1, -36, 1, 0), 2)
	title.TextSize = 18
	head.Activated:Connect(function()
		expanded = not expanded
		local message = lastMessage
		if message then
			Leaderboard.apply(message)
		end
	end)

	for i = 1, ROWS do
		table.insert(rows, row(frame, i))
	end
	youRow = row(frame, ROWS + 1)
	panel = frame
end

-- Kozmetik değişince son tabloyu yeniden doldur (çerçeve hemen görünsün).
Cosmetics.onChanged(function()
	local message = lastMessage
	if message then
		Leaderboard.apply(message)
	end
end)

-- Kaynak: yalnız hayattayken.
function Leaderboard.setVisible(visible: boolean)
	if panel then
		panel.Visible = visible
	end
	if not visible then
		lastRank = nil
	end
end

return Leaderboard
