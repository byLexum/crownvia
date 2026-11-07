--!strict
-- Roblox analitiği: karşılama hunisi (giriş → doğuş → ilk fetih → ilk yükseltme → ölüm → yeniden
-- oyna) ve ölüm/yeniden oynama sayıları. Yalnız yayınlı oyunda veri toplar; hata oyunu etkilemez.
-- Oyuncu verisi yok: yalnız adım adı. Kurallara dokunmaz.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Funnel =
	require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Account"):WaitForChild("Funnel"))

local Analytics = {}

local reached: { [Player]: number } = {}

function Analytics.step(player: Player, step: Funnel.Step)
	local index = Funnel.advance(reached[player] or 0, step)
	if index == nil then
		return
	end
	reached[player] = index
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, index, step)
	end)
end

function Analytics.event(player: Player, name: string)
	pcall(function()
		AnalyticsService:LogCustomEvent(player, name)
	end)
end

-- Ekonomi panosu (Creator Hub > Analytics > Economy): Credits nereden geliyor, nereye gidiyor.
-- `amount` pozitif; yön `source` ile. `transaction`: Enum.AnalyticsEconomyTransactionType adı
-- (Gameplay, IAP, Shop). `sku`: olay türü ya da eşya kimliği.
local CURRENCY = "Credits"

function Analytics.economy(
	player: Player,
	source: boolean,
	amount: number,
	balance: number,
	transaction: Enum.AnalyticsEconomyTransactionType,
	sku: string
)
	if amount <= 0 then
		return
	end
	pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			if source
				then Enum.AnalyticsEconomyFlowType.Source
				else Enum.AnalyticsEconomyFlowType.Sink,
			CURRENCY,
			amount,
			balance,
			transaction.Name,
			sku
		)
	end)
end

function Analytics.start()
	Players.PlayerAdded:Connect(function(player)
		Analytics.step(player, "Joined")
	end)
	for _, player in Players:GetPlayers() do
		Analytics.step(player, "Joined")
	end
	Players.PlayerRemoving:Connect(function(player)
		reached[player] = nil
	end)
end

return Analytics
