import { NeonEvent, neonEvent } from "../../../neon/src/render/event";
import { Block } from "../select/select";
import { Action, resolve } from "../input/bindings";
import { Pointer, Spot } from "../input/pointer";
import { ROWS_PER_NOTCH, Wheel, WheelRoute, route } from "../input/wheel";
import { PasteError, Vt } from "../vt/vt";
import { Pty, PtyError } from "../pty/transport";
import { Replay } from "../pty/replay";
import { Term, openTerm } from "./term";

export enum ControlError {
	VtFailed,
	KeyFailed,
	WriteFailed,
	PasteEncodeFailed,
}

export enum Pasted {
	Sent,
	Empty,
	Refused,
}

export interface Clip {
	write: (text: string) => void;
	read: (done: (text: string) => void) => void;
}

export interface Controls {
	pointer: Pointer;
	wheel: Wheel;
}

const LEFT: int32 = 1;
const RIGHT: int32 = 2;
const KEYBOARD_ROWS: int32 = ROWS_PER_NOTCH as int32;

export function open(this typeof Controls): Controls {
	return { pointer: Pointer.open(), wheel: Wheel.open() };
}

function vtOf(t: Term): Vt | null {
	const s = t.session;
	if (s === null) { return null; }
	return s.vt;
}

export function normalized(text: string): string {
	return text.split("\r\n").join("\n").split("\r").join("\n").trimEnd();
}

export function paste(this c: Controls, t: Term, text: string): Result<Pasted, ControlError> {
	const s = t.session;
	if (s === null) { return Result.ok(Pasted.Empty); }
	const clean = normalized(text);
	if (clean == "") { return Result.ok(Pasted.Empty); }
	const bytes = s.vt.pasteBytes(clean, false);
	if (!bytes.ok) {
		if (bytes.error == PasteError.Unsafe) { return Result.ok(Pasted.Refused); }
		return Result.err(ControlError.PasteEncodeFailed);
	}
	const n = bytes.value.length as int32;
	if (!s.pty.write(bytes.value[0..n]).ok) { return Result.err(ControlError.WriteFailed); }
	const _changed = try c.typed(t);
	return Result.ok(Pasted.Sent);
}

export function typed(this c: Controls, t: Term): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const bottom = vt.atBottom();
	if (!bottom.ok) { return Result.err(ControlError.VtFailed); }
	if (c.pointer.sel === null && bottom.value) { return Result.ok(false); }
	c.pointer.clear(vt);
	vt.scrollBottom();
	return Result.ok(true);
}

function pasteFrom(this c: Controls, t: Term, clip: Clip): void {
	clip.read((text: string): void => {
		const sent = c.paste(t, text);
		if (!sent.ok) {
			console.log(`haro: paste failed: ${sent.error.toString()}`);
		} else if (sent.value == Pasted.Refused) {
			console.log("haro: paste refused: it holds a line break and the program has not asked for bracketed paste");
		}
	});
}

export function keyDown(this c: Controls, t: Term, e: NeonEvent, clip: Clip): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const alt = vt.alternateScreen();
	if (!alt.ok) { return Result.err(ControlError.VtFailed); }
	const action = resolve(e.code, e.mods, alt.value);
	if (action == Action.None) { return Result.ok(false); }
	if (action == Action.Copy) { return c.copy(t, clip); }
	if (action == Action.Paste) {
		c.pasteFrom(t, clip);
		return Result.ok(true);
	}
	if (action == Action.PageUp || action == Action.PageDown) {
		if (!vt.scrollPages(action == Action.PageUp ? -1 : 1).ok) { return Result.err(ControlError.VtFailed); }
		return Result.ok(true);
	}
	match (action) {
		Action.LineUp => { vt.scrollLines(-KEYBOARD_ROWS); },
		Action.LineDown => { vt.scrollLines(KEYBOARD_ROWS); },
		Action.Top => { vt.scrollTop(); },
		_ => { vt.scrollBottom(); },
	}
	return Result.ok(true);
}

function copy(this c: Controls, t: Term, clip: Clip): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const text = c.pointer.copyText(vt);
	if (!text.ok) { return Result.err(ControlError.VtFailed); }
	const got = text.value;
	if (got === null) { return Result.ok(false); }
	clip.write(got);
	c.pointer.clear(vt);
	return Result.ok(true);
}

export function down(
	this c: Controls, t: Term, clip: Clip, button: int32, at: Spot, x: float64, y: float64, time: float64, reach: float64,
): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const modes = vt.modes();
	if (!modes.ok) { return Result.err(ControlError.VtFailed); }
	if (modes.value.mouseTracking) { return Result.ok(false); }
	if (button == LEFT) {
		const pressed = c.pointer.press(vt, at, x, y, time, reach);
		if (!pressed.ok) { return Result.err(ControlError.VtFailed); }
		return Result.ok(true);
	}
	if (button == RIGHT) {
		const copied = try c.copy(t, clip);
		if (!copied) { c.pasteFrom(t, clip); }
		return Result.ok(copied);
	}
	return Result.ok(false);
}

export function move(this c: Controls, t: Term, at: Spot, pressed: boolean): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null || !c.pointer.dragging) { return Result.ok(false); }
	if (!pressed) {
		c.pointer.release();
		return Result.ok(false);
	}
	const dragged = c.pointer.drag(vt, at);
	if (!dragged.ok) { return Result.err(ControlError.VtFailed); }
	return Result.ok(dragged.value);
}

export function up(this c: Controls): void {
	c.pointer.release();
}

export function roll(this c: Controls, t: Term, notches: float64): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const alt = vt.alternateScreen();
	const modes = vt.modes();
	if (!alt.ok || !modes.ok) { return Result.err(ControlError.VtFailed); }
	const rows = c.wheel.rows(notches);
	if (rows == 0) { return Result.ok(false); }
	const where = route(alt.value, modes.value.mouseTracking, modes.value.altScroll);
	if (where == WheelRoute.Report) { return Result.ok(false); }
	if (where == WheelRoute.Arrows) {
		c.pointer.clear(vt);
		const key = neonEvent("keydown");
		key.code = rows < 0 ? "ArrowUp" : "ArrowDown";
		const presses = rows < 0 ? -rows : rows;
		for (let i = 0; i < presses; i++) {
			if (!t.sendKey(key).ok) { return Result.err(ControlError.KeyFailed); }
		}
		return Result.ok(false);
	}
	vt.scrollLines(rows);
	if (c.pointer.dragging) {
		const dragged = c.pointer.drag(vt, c.pointer.last);
		if (!dragged.ok) { return Result.err(ControlError.VtFailed); }
	}
	return Result.ok(true);
}

export function shades(this c: Controls, t: Term): Result<Vec<Block>, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok([]); }
	if (!c.pointer.sync(vt).ok) { return Result.err(ControlError.VtFailed); }
	const drawn = c.pointer.blocks(vt, t.rows, t.cols);
	if (!drawn.ok) { return Result.err(ControlError.VtFailed); }
	return Result.ok(drawn.value);
}

interface Sink {
	sent: string;
}

interface Board {
	copied: string;
	offer: string;
	reads: int32;
}

function recorder(text: string, sink: Sink): Pty {
	const base = Replay.ofText(text).toPty();
	return {
		wait: base.wait,
		read: base.read,
		write: (data: Span<uint8>): Result<int32, PtyError> => {
			for (let i = 0; i < data.length; i++) { sink.sent += String.fromCharCode(data[i] as int32); }
			return Result.ok(data.length as int32);
		},
		resize: base.resize,
		exitCode: base.exitCode,
		close: base.close,
	};
}

function termOf(text: string, cols: int32, rows: int32, sink: Sink): Term | null {
	const opened = openTerm((c: int32, r: int32): Result<Pty, PtyError> => { return Result.ok(recorder(text, sink)); });
	if (!opened.ok) { return null; }
	const t = opened.value;
	if (!t.fit(cols, rows).ok) { return null; }
	if (!t.pumpFrame().ok) { return null; }
	return t;
}

function boardOf(offer: string): Board {
	return { copied: "", offer: offer, reads: 0 };
}

function clipOf(board: Board): Clip {
	return {
		write: (text: string): void => { board.copied = text; },
		read: (done: (text: string) => void): void => {
			board.reads += 1;
			done(board.offer);
		},
	};
}

function key(code: string, mods: int32): NeonEvent {
	const e = neonEvent("keydown");
	e.code = code;
	e.mods = mods;
	return e;
}

function lines(n: int32): string {
	let out = "";
	for (let i = 1; i <= n; i++) { out += `line ${i}\r\n`; }
	return out;
}

function offsetOf(t: Term): int32 {
	const s = t.session;
	if (s === null) { return -1; }
	return try s.vt.scrollOffset() catch -1;
}

function atBottomOf(t: Term): boolean {
	const s = t.session;
	if (s === null) { return false; }
	return try s.vt.atBottom() catch false;
}

function at(col: int32, row: int32): Spot {
	return { col: col, row: row };
}

function handled(r: Result<boolean, ControlError>): boolean {
	return r.ok && r.value;
}

function drag(c: Controls, t: Term, clip: Clip, from: Spot, to: Spot): boolean {
	const pressed = c.down(t, clip, 1, from, from.col as float64 * 8, from.row as float64 * 16, 0, 8).ok;
	const moved = c.move(t, to, true).ok;
	c.up();
	return pressed && moved;
}

test "line endings of a paste become newlines and trailing whitespace goes" {
	assert normalized("a\r\nb\rc\n") == "a\nb\nc";
	assert normalized("echo hi\r\n  ") == "echo hi";
	assert normalized("  keep leading") == "  keep leading";
	assert normalized("\r\n") == "";
}

test "ctrl shift page, arrow, home and end keys move the viewport and say they did" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert bottom > 0;
		assert atBottomOf(t);
		assert handled(c.keyDown(t, key("PageUp", 3), clip));
		assert offsetOf(t) == bottom - 5;
		assert handled(c.keyDown(t, key("ArrowUp", 3), clip));
		assert offsetOf(t) == bottom - 8;
		assert handled(c.keyDown(t, key("ArrowDown", 3), clip));
		assert offsetOf(t) == bottom - 5;
		assert handled(c.keyDown(t, key("Home", 3), clip));
		assert offsetOf(t) == 0;
		assert handled(c.keyDown(t, key("PageDown", 3), clip));
		assert offsetOf(t) == 5;
		assert handled(c.keyDown(t, key("End", 3), clip));
		assert atBottomOf(t);
		assert !handled(c.keyDown(t, key("ArrowUp", 0), clip));
		assert !handled(c.keyDown(t, key("PageUp", 0), clip));
		assert sink.sent == "";
		t.shutdown();
	}
}

test "copy takes the selected text to the clipboard and dismisses the selection, ctrl shift c and enter alike" {
	const sink: Sink = { sent: "" };
	const t = termOf("alpha beta\r\ngamma", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("");
		const clip = clipOf(board);
		assert !handled(c.keyDown(t, key("KeyC", 3), clip));
		assert !handled(c.keyDown(t, key("Enter", 0), clip));
		assert board.copied == "";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert c.pointer.selected();
		assert handled(c.keyDown(t, key("KeyC", 3), clip));
		assert board.copied == "alpha";
		assert !c.pointer.selected();
		assert !handled(c.keyDown(t, key("KeyC", 3), clip));
		assert drag(c, t, clip, at(6, 0), at(9, 0));
		assert handled(c.keyDown(t, key("Enter", 0), clip));
		assert board.copied == "beta";
		assert drag(c, t, clip, at(0, 1), at(4, 1));
		assert handled(c.keyDown(t, key("Insert", 2), clip));
		assert board.copied == "gamma";
		t.shutdown();
	}
}

test "paste sends the clipboard through the terminal's paste encoding" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("echo hi\r\n");
		const clip = clipOf(board);
		assert handled(c.keyDown(t, key("KeyV", 3), clip));
		assert board.reads == 1;
		assert sink.sent == "echo hi";
		assert handled(c.keyDown(t, key("Insert", 1), clip));
		assert sink.sent == "echo hiecho hi";
		assert !handled(c.keyDown(t, key("KeyV", 2), clip));
		assert board.reads == 2;
		t.shutdown();
	}
}

test "a paste with a line break is refused until the program asks for bracketed paste" {
	const plain: Sink = { sent: "" };
	const a = termOf("ready", 20, 5, plain);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(a, key("KeyV", 3), clip));
		assert plain.sent == "";
		a.shutdown();
	}
	const framed: Sink = { sent: "" };
	const b = termOf("\x1b[?2004h", 20, 5, framed);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(b, key("KeyV", 3), clip));
		assert framed.sent == "\x1b[200~one\ntwo\x1b[201~";
		b.shutdown();
	}
}

test "an empty clipboard pastes nothing" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const pasted = c.paste(t, "  \r\n");
		assert pasted.ok;
		if (pasted.ok) { assert pasted.value == Pasted.Empty; }
		assert sink.sent == "";
		t.shutdown();
	}
}

test "typing or pasting snaps the viewport to the bottom and drops the selection once" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		assert !handled(c.typed(t));
		assert handled(c.keyDown(t, key("PageUp", 3), clip));
		assert drag(c, t, clip, at(0, 0), at(3, 0));
		assert c.pointer.selected();
		assert handled(c.typed(t));
		assert atBottomOf(t);
		assert !c.pointer.selected();
		assert !handled(c.typed(t));
		assert handled(c.keyDown(t, key("Home", 3), clip));
		assert handled(c.keyDown(t, key("KeyV", 3), clip));
		assert atBottomOf(t);
		assert sink.sent == "x";
		t.shutdown();
	}
}

test "the wheel scrolls three rows a notch on the primary screen and accumulates fractions" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const bottom = offsetOf(t);
		assert handled(c.roll(t, 1));
		assert offsetOf(t) == bottom - 3;
		assert handled(c.roll(t, 2));
		assert offsetOf(t) == bottom - 9;
		assert handled(c.roll(t, -1));
		assert offsetOf(t) == bottom - 6;
		assert !handled(c.roll(t, 0.25));
		assert handled(c.roll(t, 0.25));
		assert offsetOf(t) == bottom - 7;
		assert sink.sent == "";
		t.shutdown();
	}
}

test "on the alternate screen the wheel is arrow keys, in the cursor key mode the program set" {
	const normal: Sink = { sent: "" };
	const a = termOf("\x1b[?1049h", 20, 5, normal);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		assert !handled(c.roll(a, 1));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A";
		assert !handled(c.roll(a, -1));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A\x1b[B\x1b[B\x1b[B";
		a.shutdown();
	}
	const app: Sink = { sent: "" };
	const b = termOf("\x1b[?1049h\x1b[?1h", 20, 5, app);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		assert !handled(c.roll(b, 1));
		assert app.sent == "\x1bOA\x1bOA\x1bOA";
		b.shutdown();
	}
	const off: Sink = { sent: "" };
	const d = termOf("\x1b[?1049h\x1b[?1007l", 20, 5, off);
	assert d !== null;
	if (d !== null) {
		const c = Controls.open();
		assert c.roll(d, 1).ok;
		assert off.sent == "";
		d.shutdown();
	}
}

test "an app that reports the mouse keeps the wheel and the buttons" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30) + "\x1b[?1000h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		const bottom = offsetOf(t);
		assert !handled(c.roll(t, 1));
		assert offsetOf(t) == bottom;
		assert !handled(c.down(t, clip, 1, at(0, 0), 0, 0, 0, 8));
		assert !c.pointer.dragging;
		assert !handled(c.down(t, clip, 2, at(0, 0), 0, 0, 0, 8));
		assert sink.sent == "";
		t.shutdown();
	}
}

test "a right click copies a selection and otherwise pastes" {
	const sink: Sink = { sent: "" };
	const t = termOf("alpha beta", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("pasted");
		const clip = clipOf(board);
		assert !handled(c.down(t, clip, 2, at(0, 0), 0, 0, 0, 8));
		assert sink.sent == "pasted";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert handled(c.down(t, clip, 2, at(0, 0), 0, 0, 1000, 8));
		assert board.copied == "alpha";
		assert sink.sent == "pasted";
		assert !c.pointer.selected();
		t.shutdown();
	}
}

test "a move that finds the button released ends the drag, and a wheel while dragging extends it" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		assert c.down(t, clip, 1, at(0, 4), 0, 64, 0, 8).ok;
		assert handled(c.move(t, at(3, 4), true));
		assert handled(c.roll(t, 1));
		const kept = c.pointer.sel;
		assert kept !== null;
		if (kept !== null) { assert kept.bounds().start.row < kept.bounds().end.row; }
		assert !handled(c.move(t, at(5, 4), false));
		assert !c.pointer.dragging;
		t.shutdown();
	}
}

test "the shades are the highlight rectangles of the viewport" {
	const sink: Sink = { sent: "" };
	const t = termOf("alpha beta\r\ngamma", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const none = c.shades(t);
		assert none.ok;
		if (none.ok) { assert none.value.length == 0; }
		assert drag(c, t, clip, at(2, 0), at(3, 1));
		const drawn = c.shades(t);
		assert drawn.ok;
		if (drawn.ok) {
			assert drawn.value.length == 2;
			assert drawn.value[0].row == 0 && drawn.value[0].col == 2 && drawn.value[0].cols == 18;
			assert drawn.value[1].row == 1 && drawn.value[1].col == 0 && drawn.value[1].cols == 4;
		}
		t.shutdown();
	}
}
