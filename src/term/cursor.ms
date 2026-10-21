import { CursorLook, CursorShape } from "../vt/vt";

export const BLINK_MS: int32 = 600;
const BLINK_RESET_MS: float64 = 500;

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
