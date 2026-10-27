import { KeyMod } from "../keys/keys";
import {
	MouseAction,
	MouseGeometry,
	MouseInput,
	Vt,
	mouseReport,
	writeText,
} from "./vt";
import { ascii, withVt } from "./vtRig";

const GEOMETRY: MouseGeometry = {
	cellWidth: 10,
	cellHeight: 20,
	width: 200,
	height: 80,
	padLeft: 0,
	padTop: 0,
	padRight: 0,
	padBottom: 0,
};

function mouseBytes(
	vt: Vt,
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
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "";
	});
}

test "SGR reporting names the cell, the button and the modifiers" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		assert mouseBytes(vt, MouseAction.Release, 1, none, false) == "\x1b[<0;3;2m";
		assert mouseBytes(vt, MouseAction.Press, 3, none, true) == "\x1b[<1;3;2M";
		assert mouseBytes(vt, MouseAction.Press, 4, none, false) == "\x1b[<64;3;2M";
		const shift = none.incl(KeyMod.Shift);
		assert mouseBytes(vt, MouseAction.Press, 1, shift, true) == "\x1b[<4;3;2M";
	});
}

function pressAt(vt: Vt, x: float32, y: float32): string {
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
		assert pressAt(vt, 5, 5) == "\x1b[<0;1;1M";
		assert pressAt(vt, 45, 55) == "\x1b[<0;2;2M";
		assert pressAt(vt, 255, 135) == "\x1b[<0;20;4M";
	});
}

test "motion is reported only under button or any-event tracking" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 1, none, true) == "";
		vt.writeText("\x1b[?1002h");
		assert mouseBytes(vt, MouseAction.Motion, 1, none, true) == "\x1b[<32;3;2M";
		vt.writeText("\x1b[?1003h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
	});
}

test "the same cell is not reported twice for motion, and SGR-pixels reports pixels" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1003h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "";
		vt.writeText("\x1b[?1016h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;25;25M";
	});
}

test "setting a mouse mode that is already on still switches the report format and event" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1000h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		vt.writeText("\x1b[?1015h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[32;3;2M";
		vt.writeText("\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Press, 1, none, true) == "\x1b[<0;3;2M";
		vt.writeText("\x1b[?1003h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		vt.writeText("\x1b[?1000h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "";
	});
}

test "same-cell motion is reported again once after any write, because the encoder rereads its modes" {
	assert withVt(20, 4, (vt: Vt): void => {
		const none = 0 as BitSet<KeyMod>;
		vt.writeText("\x1b[?1003h\x1b[?1006h");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		vt.writeText("x");
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "\x1b[<35;3;2M";
		assert mouseBytes(vt, MouseAction.Motion, 0, none, false) == "";
	});
}
