import { KeyMod } from "../keys/keys";
import {
	MouseAction,
	MouseGeometry,
	MouseInput,
	Vt,
	VtError,
	geometryOf,
	mouseReport,
	writeText,
} from "./vt";
import { ascii, withVt } from "./vtRig";

const GEOMETRY = geometryOf(10, 20, 200, 80);

function mouseBytes(
	this vt: Vt,
	action: MouseAction,
	button: int32,
	mods: BitSet<KeyMod>,
	anyPressed: boolean,
): string {
	let buf: Vec<uint8> = new Array(32);
	const e: MouseInput = { action: action, button: button, mods: mods, x: 25.0, y: 25.0 };
	const n = vt.mouseReport(e, GEOMETRY, anyPressed, buf);
	if (!n.ok) { return "error"; }
	return ascii(buf[0..n.value]);
}

test "a mouse event is silent until the program turns mouse reporting on" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		assert vt.mouseBytes(MouseAction.Press, 1, none, true) == "";
	});
}

test "SGR reporting names the cell, the button and the modifiers" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert vt.mouseBytes(MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		assert vt.mouseBytes(MouseAction.Release, 1, none, false) == "\x1b[<0;3;2m";
		assert vt.mouseBytes(MouseAction.Press, 3, none, true) == "\x1b[<1;3;2M";
		assert vt.mouseBytes(MouseAction.Press, 4, none, false) == "\x1b[<64;3;2M";
		const shift = none.incl(KeyMod.Shift);
		assert vt.mouseBytes(MouseAction.Press, 1, shift, true) == "\x1b[<4;3;2M";
	});
}

function pressAt(this vt: Vt, x: float32, y: float32): string {
	const padded: MouseGeometry = { ...GEOMETRY, width: 260, height: 140, padLeft: 30, padTop: 30, padRight: 30, padBottom: 30 };
	const e: MouseInput = { action: MouseAction.Press, button: 1, mods: 0 as BitSet<KeyMod>, x: x, y: y };
	let buf: Vec<uint8> = new Array(32);
	const n = vt.mouseReport(e, padded, true, buf);
	if (!n.ok) { return "error"; }
	return ascii(buf[0..n.value]);
}

test "a press in the padding reports the nearest cell, and the grid starts past the padding" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert vt.pressAt(5, 5) == "\x1b[<0;1;1M";
		assert vt.pressAt(45, 55) == "\x1b[<0;2;2M";
		assert vt.pressAt(255, 135) == "\x1b[<0;20;4M";
	});
}

test "motion is reported only under button or any-event tracking" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert vt.mouseBytes(MouseAction.Motion, 1, none, true) == "";
		vt.writeText("\x1b[?1002h");
		assert vt.mouseBytes(MouseAction.Motion, 1, none, true) == "\x1b[<32;3;2M";
		vt.writeText("\x1b[?1003h");
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
	});
}

test "the same cell is not reported twice for motion, and SGR-pixels reports pixels" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1003h\x1b[?1006h");
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "";
		vt.writeText("\x1b[?1016h");
		assert vt.mouseBytes(MouseAction.Press, 1, none, true) == "\x1b[<0;25;25M";
	});
}

test "setting a mouse mode that is already on still switches the report format and event" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert vt.mouseBytes(MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		vt.writeText("\x1b[?1015h");
		assert vt.mouseBytes(MouseAction.Press, 1, none, true) == "\x1b[32;3;2M";
		vt.writeText("\x1b[?1006h");
		assert vt.mouseBytes(MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		vt.writeText("\x1b[?1003h");
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		vt.writeText("\x1b[?1000h");
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "";
	});
}

test "same-cell motion is reported again once after any write, because the encoder rereads its modes" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1003h\x1b[?1006h");
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		vt.writeText("x");
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		assert vt.mouseBytes(MouseAction.Motion, 0, none, false) == "";
	});
}

test "a negative geometry is refused, not wrapped into a huge unsigned size" {
	assert withVt(20, 4, (vt: Vt): void => {
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		const e: MouseInput = { action: MouseAction.Press, button: 1, mods: 0 as BitSet<KeyMod>, x: 25.0, y: 25.0 };
		let buf: Vec<uint8> = new Array(32);
		const widths: MouseGeometry[] = [
			{ ...GEOMETRY, width: -1 },
			{ ...GEOMETRY, height: -1 },
			{ ...GEOMETRY, cellWidth: -1 },
			{ ...GEOMETRY, cellHeight: -1 },
			{ ...GEOMETRY, padLeft: -1 },
			{ ...GEOMETRY, padTop: -1 },
			{ ...GEOMETRY, padRight: -1 },
			{ ...GEOMETRY, padBottom: -1 },
		];
		for (const g of widths) {
			const refused = vt.mouseReport(e, g, true, buf);
			assert !refused.ok;
			if (!refused.ok) { assert refused.error == VtError.GeometryInvalid; }
		}
	});
}
