--!strict
-- Derived from Kiomet (c) Softbear, Inc. — AGPL-3.0-or-later. Source: common/src/ticks.rs
-- Derived from kodiak (c) Softbear, Inc. — LGPL-3.0-or-later. Source: common/src/time/ticks.rs (tag 0.1.1)

-- Kiomet'te `common/src/ticks.rs` içindeki `type Ticks = GenTicks<4>`
-- → bizde bu modül. `GenTicks<FREQUENCY_HZ>` (kodiak) 4 Hz'e sabitlenmiş haliyle çevrildi.
--
-- Ticks, 16 bitlik işaretsiz bir tamsayıdır (Rust `u16`, kodiak `TicksRepr`).
-- Luau'da düz `number` olarak tutulur; değer her zaman 0..65535 aralığında bir tamsayıdır.
--
-- Rust'taki `+`, `-`, `*` operatörleri: Kiomet'in Cargo profillerinde `overflow-checks`
-- ayarı yok, yani release derlemesinde taşma sarmalıdır (debug'da panik). Sunucu release
-- çalıştığı için `add`, `sub`, `mul` burada sarmalı (wrapping) çevrildi.

export type Ticks = number

local Ticks = {}

local REPR_MAX = 65535 -- u16::MAX
local REPR_MODULO = 65536

-- kodiak `GenTicks::FREQUENCY_HZ`
Ticks.FREQUENCY_HZ = 4
-- kodiak `GenTicks::PERIOD_SECS`
Ticks.PERIOD_SECS = 1 / Ticks.FREQUENCY_HZ
-- kodiak `TicksTrait::ZERO / ONE / MAX / SECOND`
Ticks.ZERO = 0 :: Ticks
Ticks.ONE = 1 :: Ticks
Ticks.MAX = REPR_MAX :: Ticks
Ticks.SECOND = Ticks.FREQUENCY_HZ :: Ticks

-- Rust `f32 as u16`: sıfıra doğru keser, NaN → 0, aralık dışını sınırlar.
local function floatToRepr(value: number): Ticks
	if value ~= value then
		return 0
	end
	if value <= 0 then
		return 0
	end
	if value >= REPR_MAX then
		return REPR_MAX
	end
	return math.floor(value)
end

-- Değerin geçerli bir Ticks (0..65535 tamsayı) olup olmadığı.
function Ticks.isValid(value: number): boolean
	return value >= 0 and value <= REPR_MAX and value == math.floor(value)
end

-- kodiak `GenTicks::from_secs`. Kesirli saniye; kaynakta da kayıplı.
-- Not: Rust f32, Luau double kullanır; uç değerlerde 1 tick fark olabilir (varsayım, ölçülmedi).
function Ticks.fromSecs(secs: number): Ticks
	return floatToRepr(secs * Ticks.SECOND)
end

-- kodiak `GenTicks::from_whole_secs`. `saturating_mul` kullanır.
function Ticks.fromWholeSecs(secs: number): Ticks
	return math.min(secs * Ticks.SECOND, REPR_MAX)
end

-- kodiak `GenTicks::from_whole_millis`. `u32` tamsayı bölme, taşarsa MAX.
function Ticks.fromWholeMillis(millis: number): Ticks
	local scaled = (millis * Ticks.SECOND) // 1000
	if scaled > REPR_MAX then
		return REPR_MAX
	end
	return scaled
end

-- kodiak `GenTicks::from_repr`
function Ticks.fromRepr(repr: number): Ticks
	return repr
end

-- kodiak `GenTicks::to_secs`
function Ticks.toSecs(ticks: Ticks): number
	return ticks * Ticks.PERIOD_SECS
end

-- kodiak `GenTicks::to_whole_secs` (aşağı yuvarlar)
function Ticks.toWholeSecs(ticks: Ticks): number
	return ticks // Ticks.SECOND
end

-- kodiak `GenTicks::saturating_add`
function Ticks.saturatingAdd(a: Ticks, b: Ticks): Ticks
	return math.min(a + b, REPR_MAX)
end

-- kodiak `GenTicks::saturating_sub`
function Ticks.saturatingSub(a: Ticks, b: Ticks): Ticks
	return math.max(a - b, 0)
end

-- kodiak `GenTicks::wrapping_add`
function Ticks.wrappingAdd(a: Ticks, b: Ticks): Ticks
	return (a + b) % REPR_MODULO
end

-- kodiak `GenTicks::checked_add`. Taşarsa nil (Rust `None`).
function Ticks.checkedAdd(a: Ticks, b: Ticks): Ticks?
	local sum = a + b
	if sum > REPR_MAX then
		return nil
	end
	return sum
end

-- kodiak `GenTicks::checked_sub`. Eksiye düşerse nil (Rust `None`).
function Ticks.checkedSub(a: Ticks, b: Ticks): Ticks?
	local difference = a - b
	if difference < 0 then
		return nil
	end
	return difference
end

-- kodiak `GenTicks::next` (sarmalı +1)
function Ticks.next(ticks: Ticks): Ticks
	return Ticks.wrappingAdd(ticks, Ticks.ONE)
end

-- kodiak `GenTicks::every`: `self % period == 0`.
-- Rust'ta period 0 ise sıfıra bölme paniği olur; burada da hata verilir.
function Ticks.every(ticks: Ticks, period: Ticks): boolean
	assert(period ~= 0, "Ticks.every: period must not be zero")
	return ticks % period == 0
end

-- kodiak `impl Add` (release: sarmalı)
function Ticks.add(a: Ticks, b: Ticks): Ticks
	return (a + b) % REPR_MODULO
end

-- kodiak `impl Sub` (release: sarmalı)
function Ticks.sub(a: Ticks, b: Ticks): Ticks
	return (a - b) % REPR_MODULO
end

-- kodiak `impl Mul` (release: sarmalı)
function Ticks.mul(a: Ticks, b: Ticks): Ticks
	return (a * b) % REPR_MODULO
end

-- kodiak `impl Mul<f32>`: `(self as f32 * other) as u16`
function Ticks.mulFloat(ticks: Ticks, factor: number): Ticks
	return floatToRepr(ticks * factor)
end

-- kodiak `impl Div` (tamsayı bölme). Rust'ta 0'a bölme paniktir.
function Ticks.div(a: Ticks, b: Ticks): Ticks
	assert(b ~= 0, "Ticks.div: division by zero")
	return a // b
end

-- kodiak `impl Rem`. Rust'ta 0'a bölme paniktir.
function Ticks.rem(a: Ticks, b: Ticks): Ticks
	assert(b ~= 0, "Ticks.rem: division by zero")
	return a % b
end

return table.freeze(Ticks)
