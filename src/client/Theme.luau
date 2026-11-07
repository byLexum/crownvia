--!strict
-- CROWNVIA görsel tokenları. Arayüz parçaları `Kit.luau`.
-- Renkler oyun dünyası ve arayüz için tek kaynak.

local Theme = {}

Theme.colors = {
	-- Arayüz (F: Rounded Arcade Navy, 2026-11-06). Anlamlar sabit: altın = ana eylem ve Credits,
	-- yeşil = Robux satın alma, `alert` = acil savaş uyarısı.
	background = Color3.fromRGB(11, 17, 32),
	panel = Color3.fromRGB(19, 28, 52),
	panelRaised = Color3.fromRGB(28, 41, 74),
	well = Color3.fromRGB(14, 21, 40),
	stroke = Color3.fromRGB(60, 80, 124),
	navy = Color3.fromRGB(44, 62, 108),
	navyLip = Color3.fromRGB(24, 35, 64),
	gold = Color3.fromRGB(247, 182, 62),
	goldLip = Color3.fromRGB(168, 96, 28),
	onGold = Color3.fromRGB(38, 24, 8),
	green = Color3.fromRGB(44, 176, 110),
	greenLip = Color3.fromRGB(22, 108, 70),
	alert = Color3.fromRGB(216, 48, 56),
	alertLip = Color3.fromRGB(128, 22, 34),
	-- Harita zemini (kaynakta `midnight × 0.8`, background.frag).
	fog = Color3.fromRGB(35, 50, 64),
	-- Görünen kara (Codex `ground`).
	land = Color3.fromRGB(184, 176, 158),
	-- Hedef görünüm B: çimen, toprak yol, ağaç ve kaya.
	grass = Color3.fromRGB(132, 168, 98),
	grassDeep = Color3.fromRGB(112, 152, 86),
	sand = Color3.fromRGB(222, 206, 166),
	-- Keşfedilmemiş alan: soluk, koyu çimen.
	unexplored = Color3.fromRGB(86, 104, 82),
	dirt = Color3.fromRGB(206, 188, 150),
	leaf = Color3.fromRGB(88, 134, 74),
	leafDark = Color3.fromRGB(62, 104, 66),
	trunk = Color3.fromRGB(110, 84, 62),
	rock = Color3.fromRGB(150, 150, 146),
	-- Harita zenginliği (2026-11-04): kuru çimen lekesi, ılık kaya, kum torbası, çam tonları.
	grassDry = Color3.fromRGB(156, 170, 104),
	rockWarm = Color3.fromRGB(146, 140, 128),
	sandbag = Color3.fromRGB(176, 160, 122),
	pine = Color3.fromRGB(64, 104, 70),
	pineLight = Color3.fromRGB(84, 126, 80),
	-- Görüş dışı bulut denizi (Fog.luau): taban biraz mavi-gri, kümeler açık.
	cloudSea = Color3.fromRGB(190, 204, 216),
	-- Doku (MaterialVariant) renkleri parça rengiyle çarpılır: beyaz = dokunun kendi rengi.
	textureTint = Color3.new(1, 1, 1),
	cloud = Color3.fromRGB(242, 245, 248),
	cloudShade = Color3.fromRGB(205, 216, 228),
	text = Color3.fromRGB(242, 244, 237),
	muted = Color3.fromRGB(156, 172, 206),
	-- Yükleme ekranı logo ışıltısı (sıcak altın, çok düşük opaklıkla katmanlanır).
	glow = Color3.fromRGB(255, 188, 96),
	own = Color3.fromRGB(98, 182, 255),
	enemy = Color3.fromRGB(255, 115, 103),
	ally = Color3.fromRGB(180, 156, 255),
	neutral = Color3.fromRGB(196, 186, 164),
	crown = Color3.fromRGB(244, 199, 107),
	route = Color3.fromRGB(140, 214, 175),
	danger = Color3.fromRGB(255, 115, 103),
}

-- Baloncuklu yazı tipi bilinçli olarak yok: Montserrat ciddiyeti korur.
Theme.fonts = {
	heading = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.ExtraBold),
	strong = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold),
	body = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.SemiBold),
}

return Theme
