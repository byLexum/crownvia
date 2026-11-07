--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/info.rs, common/src/death_reason.rs

-- Kiomet'te `common/src/info.rs` içindeki `InfoEvent` / `Info` → bizde bu modül.
-- Konum (`position: Vec2`) yerine olayın kule id'si tutulur; istemci konumu kendisi hesaplar.

export type GainedTowerReason = "CapturedFrom" | "Explored" | "Spawned"
export type LostTowerReason = "CapturedBy" | "DestroyedBy" | "PlayerKilled"

export type InfoEvent =
	{
		kind: "GainedTower",
		towerId: number,
		playerId: number,
		reason: GainedTowerReason,
		from: number?,
	}
	| { kind: "LostTower", towerId: number, playerId: number, reason: LostTowerReason, by: number? }
	| { kind: "LostForce", towerId: number, playerId: number }
	-- "Oyuncu öldürüldüğünde ateşlenmez" (info.rs).
	| { kind: "LostRuler", towerId: number, playerId: number, killedBy: number?, unit: number }
	| { kind: "Emp", towerId: number, playerId: number? }
	| { kind: "NuclearExplosion", towerId: number }
	| { kind: "ShellExplosion", towerId: number }

export type OnInfo = (InfoEvent) -> ()

-- `DeathReason::RulerKilled { alias, unit }`. alias nil → sahipsiz birimler (zombi) öldürdü.
export type DeathReason = { alias: string?, unit: number }

return {}
