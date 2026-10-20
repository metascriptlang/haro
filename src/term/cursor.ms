import { CursorLook, CursorShape } from "../vt/vt";

export struct Box {
	x: float64;
	y: float64;
	w: float64;
	h: float64;
	alpha: float64;
}

export const NO_BOX: Box = { x: 0, y: 0, w: 0, h: 0, alpha: 0 };
export const BOX_SLOTS: int32 = 4;
export const BLINK_MS: int32 = 600;
const BLINK_RESET_MS: float64 = 500;

export function drawn(look: CursorLook, focused: boolean, blinkOn: boolean): boolean {
	if (!look.visible) { return false; }
	if (!focused) { return true; }
	return !look.blinking || blinkOn;
}

export function shapeOf(look: CursorLook, focused: boolean): CursorShape {
	return focused ? look.shape : CursorShape.BlockHollow;
}

export function blinks(look: CursorLook, focused: boolean): boolean {
	return look.visible && look.blinking && focused;
}

export function resets(last: float64, now: float64): boolean {
	return now - last > BLINK_RESET_MS;
}

export function boxes(
	shape: CursorShape,
	col: int32,
	row: int32,
	cellWidth: float64,
	rowHeight: float64,
	thickness: float64,
): Vec<Box> {
	const x = (col as float64) * cellWidth;
	const y = (row as float64) * rowHeight;
	const sideHeight = rowHeight - 2 * thickness;
	const rightX = x + cellWidth - thickness;
	return match (shape) {
		CursorShape.Block => [{ x: x, y: y, w: cellWidth, h: rowHeight, alpha: 0.5 }],
		CursorShape.Bar => [{ x: x - thickness / 2, y: y, w: thickness, h: rowHeight, alpha: 1 }],
		CursorShape.Underline => [
			{ x: x, y: y + rowHeight - 2 * thickness, w: cellWidth, h: thickness, alpha: 1 },
		],
		CursorShape.BlockHollow => [
			{ x: x, y: y, w: cellWidth, h: thickness, alpha: 1 },
			{ x: x, y: y + rowHeight - thickness, w: cellWidth, h: thickness, alpha: 1 },
			{ x: x, y: y + thickness, w: thickness, h: sideHeight, alpha: 1 },
			{ x: rightX, y: y + thickness, w: thickness, h: sideHeight, alpha: 1 },
		],
	};
}

function box(x: float64, y: float64, w: float64, h: float64, alpha: float64): Box {
	return { x: x, y: y, w: w, h: h, alpha: alpha };
}

function look(visible: boolean, shape: CursorShape, blinking: boolean): CursorLook {
	return { visible: visible, shape: shape, blinking: blinking };
}

test "a hidden cursor is not drawn, a steady one always is, a blinking one only while blink is on" {
	assert !drawn(look(false, CursorShape.Block, false), true, true);
	assert !drawn(look(false, CursorShape.Block, false), false, true);
	assert drawn(look(true, CursorShape.Bar, false), true, false);
	assert drawn(look(true, CursorShape.Bar, true), true, true);
	assert !drawn(look(true, CursorShape.Bar, true), true, false);
}

test "an unfocused window shows a hollow block that does not blink" {
	const blinking = look(true, CursorShape.Bar, true);
	assert drawn(blinking, false, false);
	assert shapeOf(blinking, false) == CursorShape.BlockHollow;
	assert shapeOf(blinking, true) == CursorShape.Bar;
	assert !blinks(blinking, false);
	assert blinks(blinking, true);
	assert !blinks(look(true, CursorShape.Bar, false), true);
	assert !blinks(look(false, CursorShape.Bar, true), true);
}

test "a block cursor is one translucent box over its cell" {
	const block = boxes(CursorShape.Block, 2, 1, 8, 16, 1);
	assert block.length == 1;
	assert block[0] == box(16, 16, 8, 16, 0.5);
}

test "a bar cursor is a thin box centred on the cell's left edge" {
	const bar = boxes(CursorShape.Bar, 2, 1, 8, 16, 1);
	assert bar[0] == box(15.5, 16, 1, 16, 1);
}

test "an underline cursor is a thin box near the cell's bottom" {
	const underline = boxes(CursorShape.Underline, 2, 1, 8, 16, 1);
	assert underline[0] == box(16, 30, 8, 1, 1);
}

test "a hollow block is four edges that do not overlap" {
	const edges = boxes(CursorShape.BlockHollow, 0, 0, 8, 16, 1);
	assert edges.length == 4;
	assert edges[0] == box(0, 0, 8, 1, 1);
	assert edges[1] == box(0, 15, 8, 1, 1);
	assert edges[2] == box(0, 1, 1, 14, 1);
	assert edges[3] == box(7, 1, 1, 14, 1);
}

test "output resets the blink at most once every half second" {
	assert resets(0, 501);
	assert !resets(0, 500);
	assert !resets(100, 400);
}
