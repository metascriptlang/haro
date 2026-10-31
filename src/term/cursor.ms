import { CursorLook, CursorShape } from "../vt/vt";

export const BLINK_MS: int32 = 600;
const BLINK_RESET_MS: float64 = 500;

export const GLITCH_SLOT_MS: float64 = 30;
export const GLITCH_BANDS: int32 = 3;
const GLITCH_SLOTS: int32 = 6;
const GLITCH_MAX_DARK: int32 = 2;
const GLITCH_DARK_CHANCE: float64 = 0.4;
const GLITCH_SHIFT_CHANCE: float64 = 0.5;
const GLITCH_MAX_SHIFT: float64 = 0.35;
const GLITCH_REST_MS: float64 = 1400;
const GLITCH_REST_SPREAD_MS: float64 = 2200;

export interface GlitchFrame {
	lit: boolean;
	shifts: float64[];
}

export function drawn(this look: CursorLook, focused: boolean, blinkOn: boolean): boolean {
	if (!look.visible) { return false; }
	if (!focused) { return true; }
	return !look.blinking || blinkOn;
}

export function shapeOf(this look: CursorLook, focused: boolean): CursorShape {
	return focused ? look.shape : CursorShape.BlockHollow;
}

export function blinks(this look: CursorLook, focused: boolean): boolean {
	return look.visible && look.blinking && focused;
}

export function resets(last: float64, now: float64): boolean {
	return now - last > BLINK_RESET_MS;
}

export function glitches(this look: CursorLook, focused: boolean): boolean {
	return look.blinks(focused) && look.shape == CursorShape.Block;
}

export function glitchBurst(draw: () => float64): GlitchFrame[] {
	let burst: GlitchFrame[] = [];
	let dark: int32 = 0;
	for (let i: int32 = 0; i < GLITCH_SLOTS; i++) {
		const edge = i == 0 || i == GLITCH_SLOTS - 1;
		const lit = edge || dark == GLITCH_MAX_DARK || draw() >= GLITCH_DARK_CHANCE;
		if (!lit) { dark += 1; }
		let shifts: float64[] = [];
		for (let b: int32 = 0; b < GLITCH_BANDS; b++) {
			shifts.push(draw() < GLITCH_SHIFT_CHANCE ? 0 : (draw() * 2 - 1) * GLITCH_MAX_SHIFT);
		}
		burst.push({ lit: lit, shifts: shifts });
	}
	return burst;
}

export function slotAt(this burst: GlitchFrame[], elapsed: float64): GlitchFrame | null {
	const i = Math.floor(elapsed / GLITCH_SLOT_MS) as int32;
	return i >= 0 && i < burst.length ? burst[i] : null;
}

export function glitchRest(draw: () => float64): int32 {
	return (GLITCH_REST_MS + draw() * GLITCH_REST_SPREAD_MS) as int32;
}

function look(visible: boolean, shape: CursorShape, blinking: boolean): CursorLook {
	return { visible: visible, shape: shape, blinking: blinking };
}

test "a hidden cursor is not drawn, a steady one always is, a blinking one only while blink is on" {
	assert !look(false, CursorShape.Block, false).drawn(true, true);
	assert !look(false, CursorShape.Block, false).drawn(false, true);
	assert look(true, CursorShape.Bar, false).drawn(true, false);
	assert look(true, CursorShape.Bar, true).drawn(true, true);
	assert !look(true, CursorShape.Bar, true).drawn(true, false);
}

test "an unfocused window shows a hollow block that does not blink" {
	const blinking = look(true, CursorShape.Bar, true);
	assert blinking.drawn(false, false);
	assert blinking.shapeOf(false) == CursorShape.BlockHollow;
	assert blinking.shapeOf(true) == CursorShape.Bar;
	assert !blinking.blinks(false);
	assert blinking.blinks(true);
	assert !look(true, CursorShape.Bar, false).blinks(true);
	assert !look(false, CursorShape.Bar, true).blinks(true);
}

test "output resets the blink at most once every half second" {
	assert resets(0, 501);
	assert !resets(0, 500);
	assert !resets(100, 400);
}

test "only a focused blinking block glitches; a bar or underline keeps the plain blink" {
	assert look(true, CursorShape.Block, true).glitches(true);
	assert !look(true, CursorShape.Block, true).glitches(false);
	assert !look(true, CursorShape.Block, false).glitches(true);
	assert !look(true, CursorShape.Bar, true).glitches(true);
	assert !look(true, CursorShape.Underline, true).glitches(true);
}

test "a burst starts and ends lit and goes dark at most twice, however dark its draws" {
	const dark = glitchBurst((): float64 => 0);
	assert dark.length == 6;
	let unlit = 0;
	for (const f of dark) {
		if (!f.lit) { unlit += 1; }
		assert f.shifts.length == 3 && f.shifts[0] == 0;
	}
	assert dark[0].lit && dark[5].lit && unlit == 2;
	const bright = glitchBurst((): float64 => 0.99);
	for (const f of bright) {
		assert f.lit;
		assert f.shifts[2] > 0.34 && f.shifts[2] < 0.35;
	}
}

test "a burst lasts six slots of thirty milliseconds, and the rest between bursts is 1.4 to 3.6 seconds" {
	const burst = glitchBurst((): float64 => 0);
	assert burst.slotAt(0) !== null;
	const lastSlot = burst.slotAt(179);
	assert lastSlot !== null && lastSlot.lit;
	assert burst.slotAt(180) === null;
	assert glitchRest((): float64 => 0) == 1400;
	assert glitchRest((): float64 => 0.999) < 3600;
}
