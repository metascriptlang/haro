import { NeonEvent, neonEvent } from "../../../neon/src/render/event";
import { KeyMod } from "../keys/keys";
import { Block } from "../select/select";
import { Action, BindAction, CLIPBOARD_MODS, Keybind, Screen, bindFor, resolve } from "../input/bindings";
import { Pointer, Spot, autoscrollOf, claimsMouse } from "../input/pointer";
import { ROWS_PER_NOTCH, Wheel, WheelRoute, reportButton, route } from "../input/wheel";
import { Held, Reply, replyTo, replyToRead, warningFor, Warning } from "../input/paste";
import { openable } from "../term/link";
import { MouseAction, MouseGeometry, MouseInput, Vt } from "../vt/vt";
import { Term, TermError } from "./term";
import { Sink, termOf } from "./termTest";

export enum ControlError {
	VtFailed,
	KeyFailed,
	WriteFailed,
	PasteEncodeFailed,
	PasteUnsafe,
	MouseFailed,
}

export enum Pasted {
	Sent,
	Empty,
	Held,
}

export interface Bridge {
	write: (text: string) => void;
	read: (done: (text: string) => void) => void;
	open: (uri: string) => void;
	close: () => void;
}

export struct Hit {
	at: Spot;
	x: float64;
	y: float64;
	scale: float64;
	mods: int32;
	cell: MouseGeometry;
}

export interface Controls {
	pointer: Pointer;
	wheel: Wheel;
	held: Held | null;
	reading: string | null;
	button: int32;
	autoscroll: int32;
	keybinds: Vec<Keybind>;
}

const LEFT: int32 = 1;
const RIGHT: int32 = 2;
const SHIFT: int32 = 1;
const CTRL: int32 = 2;
const SUPER: int32 = 8;
const KEYBOARD_ROWS: int32 = ROWS_PER_NOTCH as int32;

export function open(this typeof Controls): Controls {
	return { pointer: Pointer.open(), wheel: Wheel.open(), held: null, reading: null, button: 0, autoscroll: 0, keybinds: [] };
}

function vtOf(t: Term): Vt | null {
	const s = t.session;
	if (s === null) { return null; }
	return s.vt;
}

export function normalized(text: string, bracketed: boolean): string {
	const lf = text.split("\r\n").join("\n").split("\r").join("\n");
	return bracketed ? lf : lf.trimEnd();
}

function send(this c: Controls, t: Term, text: string, allowUnsafe: boolean): Result<boolean, ControlError> {
	const sent = t.sendPaste(text, allowUnsafe);
	if (!sent.ok) {
		return Result.err(match (sent.error) {
			TermError.PasteUnsafe => ControlError.PasteUnsafe,
			TermError.WriteFailed => ControlError.WriteFailed,
			_ => ControlError.PasteEncodeFailed,
		});
	}
	return c.typed(t);
}

export function paste(this c: Controls, t: Term, text: string): Result<Pasted, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(Pasted.Empty); }
	const modes = vt.modes();
	if (!modes.ok) { return Result.err(ControlError.VtFailed); }
	const bracketed = modes.value.bracketedPaste;
	const clean = normalized(text, bracketed);
	if (clean == "" && !bracketed) { return Result.ok(Pasted.Empty); }
	const warning = warningFor(clean, bracketed);
	if (warning != Warning.None) {
		c.held = { text: clean, warning: warning };
		return Result.ok(Pasted.Held);
	}
	const _sent = try c.send(t, clean, false);
	return Result.ok(Pasted.Sent);
}

export function holding(this c: Controls): boolean {
	return c.held !== null || c.reading !== null;
}

function answerClipboard(this c: Controls, t: Term, text: string, allow: boolean): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	if (!vt.answerClipboard(text, allow).ok) { return Result.err(ControlError.VtFailed); }
	if (!t.sendReplies().ok) { return Result.err(ControlError.WriteFailed); }
	return Result.ok(true);
}

export function asked(this c: Controls, t: Term, host: Bridge): void {
	host.read((text: string): void => {
		if (text == "") {
			const answered = c.answerClipboard(t, "", true);
			if (!answered.ok) { console.log(`haro: clipboard answer failed: ${answered.error.toString()}`); }
			return;
		}
		c.reading = text;
	});
}

export function confirm(this c: Controls, t: Term): Result<boolean, ControlError> {
	const held = c.held;
	if (held !== null) {
		c.held = null;
		const _sent = try c.send(t, held.text, true);
		return Result.ok(true);
	}
	const reading = c.reading;
	if (reading === null) { return Result.ok(false); }
	c.reading = null;
	return c.answerClipboard(t, reading, true);
}

export function cancel(this c: Controls, t: Term): Result<boolean, ControlError> {
	if (c.held !== null) {
		c.held = null;
		return Result.ok(true);
	}
	if (c.reading === null) { return Result.ok(false); }
	c.reading = null;
	return c.answerClipboard(t, "", false);
}

function answer(this c: Controls, t: Term, e: NeonEvent): Result<boolean, ControlError> {
	const reply = c.held !== null ? replyTo(e.code, e.mods) : replyToRead(e.code, e.mods);
	if (reply == Reply.Confirm) {
		const _sent = try c.confirm(t);
	} else if (reply == Reply.Cancel) {
		const _dropped = try c.cancel(t);
	}
	return Result.ok(true);
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

function pasteFrom(this c: Controls, t: Term, host: Bridge): void {
	host.read((text: string): void => {
		const sent = c.paste(t, text);
		if (!sent.ok) { console.log(`haro: paste failed: ${sent.error.toString()}`); }
	});
}

export function keyDown(this c: Controls, t: Term, e: NeonEvent, host: Bridge): Result<boolean, ControlError> {
	if (c.holding()) { return c.answer(t, e); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const alt = vt.alternateScreen();
	if (!alt.ok) { return Result.err(ControlError.VtFailed); }
	const bind = bindFor(c.keybinds, e.code, e.mods, alt.value);
	if (bind !== null && bind.action == BindAction.CloseWindow) {
		host.close();
		return Result.ok(true);
	}
	if (bind !== null) {
		if (!t.sendText(bind.text).ok) { return Result.err(ControlError.WriteFailed); }
		const _snapped = try c.typed(t);
		return Result.ok(true);
	}
	const action = resolve(e.code, e.mods, alt.value);
	if (action == Action.None) { return Result.ok(false); }
	if (action == Action.Copy) { return c.copy(t, host); }
	if (action == Action.Paste) {
		c.pasteFrom(t, host);
		return Result.ok(true);
	}
	if (action == Action.PageUp || action == Action.PageDown) {
		if (!vt.scrollPages(action == Action.PageUp ? -1 : 1).ok) { return Result.err(ControlError.VtFailed); }
		return Result.ok(true);
	}
	if (action == Action.PromptUp || action == Action.PromptDown) {
		if (!vt.jumpToPrompt(action == Action.PromptUp ? -1 : 1).ok) { return Result.err(ControlError.VtFailed); }
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

function copy(this c: Controls, t: Term, host: Bridge): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const text = c.pointer.copyText(vt);
	if (!text.ok) { return Result.err(ControlError.VtFailed); }
	const got = text.value;
	if (got === null) { return Result.ok(false); }
	host.write(got);
	c.pointer.clear(vt);
	return Result.ok(true);
}

function report(
	this c: Controls, t: Term, action: MouseAction, button: int32, h: Hit, anyPressed: boolean,
): Result<boolean, ControlError> {
	const input: MouseInput = {
		action: action,
		button: button,
		mods: (h.mods as uint16) as BitSet<KeyMod>,
		x: (h.x * h.scale) as float32,
		y: (h.y * h.scale) as float32,
	};
	const sent = t.sendMouse(input, h.cell, anyPressed);
	if (!sent.ok) { return Result.err(match (sent.error) {
		TermError.WriteFailed => ControlError.WriteFailed,
		_ => ControlError.MouseFailed,
	}); }
	return Result.ok(sent.value > 0);
}

function follow(host: Bridge, uri: string): void {
	if (openable(uri)) {
		host.open(uri);
	} else {
		console.log(`haro: link refused, only http and https open: ${uri}`);
	}
}

export function down(
	this c: Controls, t: Term, host: Bridge, button: int32, h: Hit, time: float64,
): Result<boolean, ControlError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const modes = vt.modes();
	if (!modes.ok) { return Result.err(ControlError.VtFailed); }
	if (button == LEFT && (h.mods & CTRL) != 0) {
		const link = vt.linkAt(h.at.col, h.at.row);
		if (!link.ok) { return Result.err(ControlError.VtFailed); }
		const uri = link.value;
		if (uri !== null) {
			follow(host, uri);
			return Result.ok(true);
		}
	}
	if (claimsMouse(modes.value.mouseTracking, (h.mods & SHIFT) != 0)) {
		c.pointer.clear(vt);
		c.button = button;
		return c.report(t, MouseAction.Press, button, h, true);
	}
	if (button == LEFT) {
		const reach = (h.cell.cellWidth as float64) / h.scale;
		const pressed = c.pointer.press(vt, h.at, h.x, h.y, time, reach);
		if (!pressed.ok) { return Result.err(ControlError.VtFailed); }
		return Result.ok(true);
	}
	if (button == RIGHT) {
		const copied = try c.copy(t, host);
		if (!copied) { c.pasteFrom(t, host); }
		return Result.ok(copied);
	}
	return Result.ok(false);
}

export function move(this c: Controls, t: Term, h: Hit, pressed: boolean): Result<boolean, ControlError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const modes = vt.modes();
	if (!modes.ok) { return Result.err(ControlError.VtFailed); }
	if (claimsMouse(modes.value.mouseTracking, (h.mods & SHIFT) != 0)) {
		if (!pressed) { c.button = 0; }
		const _reported = try c.report(t, MouseAction.Motion, c.button, h, c.button != 0);
		return Result.ok(false);
	}
	if (!c.pointer.dragging) {
		c.autoscroll = 0;
		return Result.ok(false);
	}
	if (!pressed) {
		c.pointer.release();
		c.autoscroll = 0;
		return Result.ok(false);
	}
	c.autoscroll = autoscrollOf(h.y * h.scale, h.cell.height);
	const dragged = c.pointer.drag(vt, h.at);
	if (!dragged.ok) { return Result.err(ControlError.VtFailed); }
	return Result.ok(dragged.value);
}

export function up(this c: Controls, t: Term, button: int32, h: Hit): Result<boolean, ControlError> {
	const reported = c.button != 0;
	c.pointer.release();
	c.autoscroll = 0;
	if (!reported || c.holding()) { return Result.ok(false); }
	c.button = 0;
	return c.report(t, MouseAction.Release, button, h, false);
}

export function autoscrollTick(this c: Controls, t: Term): Result<boolean, ControlError> {
	const vt = vtOf(t);
	if (vt === null || !c.pointer.dragging || c.autoscroll == 0) {
		c.autoscroll = 0;
		return Result.ok(false);
	}
	vt.scrollLines(c.autoscroll);
	const dragged = c.pointer.drag(vt, c.pointer.last);
	if (!dragged.ok) { return Result.err(ControlError.VtFailed); }
	return Result.ok(true);
}

export function roll(this c: Controls, t: Term, notches: float64, h: Hit): Result<boolean, ControlError> {
	if (c.holding()) { return Result.ok(false); }
	const vt = vtOf(t);
	if (vt === null) { return Result.ok(false); }
	const alt = vt.alternateScreen();
	const modes = vt.modes();
	if (!alt.ok || !modes.ok) { return Result.err(ControlError.VtFailed); }
	const rows = c.wheel.rows(notches);
	if (rows == 0) { return Result.ok(false); }
	const shift = (h.mods & SHIFT) != 0;
	const claimed = claimsMouse(modes.value.mouseTracking, shift);
	const where = route(alt.value, claimed, modes.value.altScroll && !shift);
	const presses = rows < 0 ? -rows : rows;
	if (where == WheelRoute.Report) {
		for (let i = 0; i < presses; i++) {
			const _reported = try c.report(t, MouseAction.Press, reportButton(rows < 0), h, false);
		}
		return Result.ok(false);
	}
	if (where == WheelRoute.Arrows) {
		c.pointer.clear(vt);
		const key = neonEvent("keydown");
		key.code = rows < 0 ? "ArrowUp" : "ArrowDown";
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

interface Board {
	opened: string;
	copied: string;
	offer: string;
	reads: int32;
	closed: int32;
}


function boardOf(offer: string): Board {
	return { opened: "", copied: "", offer: offer, reads: 0, closed: 0 };
}

function clipOf(board: Board): Bridge {
	return {
		write: (text: string): void => { board.copied = text; },
		open: (uri: string): void => { board.opened = uri; },
		close: (): void => { board.closed += 1; },
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

function hitAt(col: int32, row: int32): Hit {
	return hitWith(col, row, 0);
}

function hitWith(col: int32, row: int32, mods: int32): Hit {
	return {
		at: at(col, row), x: col as float64 * 8, y: row as float64 * 16, scale: 1, mods: mods,
		cell: { cellWidth: 8, cellHeight: 16, width: 160, height: 80 },
	};
}

function drag(c: Controls, t: Term, clip: Bridge, from: Spot, to: Spot): boolean {
	const pressed = c.down(t, clip, 1, hitAt(from.col, from.row), 0).ok;
	const moved = c.move(t, hitAt(to.col, to.row), true).ok;
	const _released = c.up(t, 1, hitAt(to.col, to.row));
	return pressed && moved;
}

test "line endings of a paste become newlines and an unbracketed paste loses trailing whitespace" {
	assert normalized("a\r\nb\rc\n", false) == "a\nb\nc";
	assert normalized("echo hi\r\n  ", false) == "echo hi";
	assert normalized("echo hi\r\n  ", true) == "echo hi\n  ";
	assert normalized("  keep leading", false) == "  keep leading";
	assert normalized("\r\n", false) == "";
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

test "copy takes the selected text to the clipboard and dismisses the selection, the copy chord and enter alike" {
	const sink: Sink = { sent: "" };
	const t = termOf("alpha beta\r\ngamma", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("");
		const clip = clipOf(board);
		assert !handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert !handled(c.keyDown(t, key("Enter", 0), clip));
		assert board.copied == "";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert c.pointer.selected();
		assert handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert board.copied == "alpha";
		assert !c.pointer.selected();
		assert !handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert drag(c, t, clip, at(6, 0), at(9, 0));
		assert handled(c.keyDown(t, key("Enter", 0), clip));
		assert board.copied == "beta";
		when (!macos) {
			assert drag(c, t, clip, at(0, 1), at(4, 1));
			assert handled(c.keyDown(t, key("Insert", 2), clip));
			assert board.copied == "gamma";
		}
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
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert board.reads == 1;
		assert sink.sent == "echo hi";
		when (!macos) {
			assert handled(c.keyDown(t, key("Insert", 1), clip));
			assert sink.sent == "echo hiecho hi";
		}
		const reads = board.reads;
		assert !handled(c.keyDown(t, key("KeyV", 2), clip));
		assert board.reads == reads;
		t.shutdown();
	}
}

test "a paste with a line break waits for an answer and sends nothing meanwhile" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert c.holding();
		const held = c.held;
		assert held !== null;
		if (held !== null) {
			assert held.warning == Warning.MultiLine;
			assert held.text == "one\ntwo";
		}
		assert sink.sent == "";
		assert handled(c.keyDown(t, key("KeyA", 0), clip));
		assert handled(c.keyDown(t, key("ArrowUp", 3), clip));
		assert handled(c.keyDown(t, key("KeyC", CLIPBOARD_MODS), clip));
		assert sink.sent == "";
		assert c.holding();
		t.shutdown();
	}
}

test "enter confirms a held paste and it goes out through the paste encoding" {
	const plain: Sink = { sent: "" };
	const a = termOf("ready", 20, 5, plain);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(a, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(a, key("Enter", 0), clip));
		assert !c.holding();
		assert plain.sent == "one\rtwo";
		a.shutdown();
	}
	const chord: Sink = { sent: "" };
	const b = termOf("ready", 20, 5, chord);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(b, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(b, key("KeyV", CLIPBOARD_MODS), clip));
		assert chord.sent == "one\rtwo";
		b.shutdown();
	}
}

test "escape drops a held paste and the next key reaches the shell again" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("one\r\ntwo"));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.keyDown(t, key("Escape", 0), clip));
		assert !c.holding();
		assert sink.sent == "";
		assert !handled(c.keyDown(t, key("KeyA", 0), clip));
		t.shutdown();
	}
}

test "the buttons confirm and cancel through the same paths as the keys" {
	const sink: Sink = { sent: "" };
	const t = termOf("ready", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("a\nb"));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		const _dropped = c.cancel(t);
		assert !c.holding();
		assert sink.sent == "";
		assert !handled(c.confirm(t));
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert handled(c.confirm(t));
		assert sink.sent == "a\rb";
		t.shutdown();
	}
}

test "bracketed paste takes line breaks as they are and an end marker or a large text still asks" {
	const framed: Sink = { sent: "" };
	const a = termOf("\x1b[?2004h", 20, 5, framed);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		assert handled(c.keyDown(a, key("KeyV", CLIPBOARD_MODS), clipOf(boardOf("one\r\ntwo\r\n"))));
		assert framed.sent == "\x1b[200~one\ntwo\n\x1b[201~";
		assert !c.holding();
		const marker = c.paste(a, "evil\x1b[201~rm");
		assert marker.ok;
		if (marker.ok) { assert marker.value == Pasted.Held; }
		const held = c.held;
		assert held !== null;
		if (held !== null) { assert held.warning == Warning.EndMarker; }
		assert handled(c.keyDown(a, key("Enter", 0), clipOf(boardOf(""))));
		assert framed.sent == "\x1b[200~one\ntwo\n\x1b[201~\x1b[200~evil [201~rm\x1b[201~";
		let big = "";
		for (let i = 0; i < 6000; i++) { big += "z"; }
		const large = c.paste(a, big);
		assert large.ok;
		if (large.ok) { assert large.value == Pasted.Held; }
		a.shutdown();
	}
}

test "an empty clipboard pastes nothing, except an empty frame when the program asked for brackets" {
	const plain: Sink = { sent: "" };
	const a = termOf("ready", 20, 5, plain);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const pasted = c.paste(a, "  \r\n");
		assert pasted.ok;
		if (pasted.ok) { assert pasted.value == Pasted.Empty; }
		assert plain.sent == "";
		a.shutdown();
	}
	const framed: Sink = { sent: "" };
	const b = termOf("\x1b[?2004h", 20, 5, framed);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		const pasted = c.paste(b, "");
		assert pasted.ok;
		if (pasted.ok) { assert pasted.value == Pasted.Sent; }
		assert framed.sent == "\x1b[200~\x1b[201~";
		b.shutdown();
	}
}

test "while a paste is held the wheel, the buttons and the pointer do nothing" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("a\nb"));
		const bottom = offsetOf(t);
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom;
		assert !handled(c.down(t, clip, 1, hitAt(0, 0), 0));
		assert !c.pointer.dragging;
		assert !handled(c.down(t, clip, 2, hitAt(0, 0), 0));
		assert clip.write !== null;
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
		assert handled(c.keyDown(t, key("KeyV", CLIPBOARD_MODS), clip));
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
		assert handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom - 3;
		assert handled(c.roll(t, 2, hitAt(0, 0)));
		assert offsetOf(t) == bottom - 9;
		assert handled(c.roll(t, -1, hitAt(0, 0)));
		assert offsetOf(t) == bottom - 6;
		assert !handled(c.roll(t, 0.25, hitAt(0, 0)));
		assert handled(c.roll(t, 0.25, hitAt(0, 0)));
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
		assert !handled(c.roll(a, 1, hitAt(0, 0)));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A";
		assert !handled(c.roll(a, -1, hitAt(0, 0)));
		assert normal.sent == "\x1b[A\x1b[A\x1b[A\x1b[B\x1b[B\x1b[B";
		a.shutdown();
	}
	const app: Sink = { sent: "" };
	const b = termOf("\x1b[?1049h\x1b[?1h", 20, 5, app);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		assert !handled(c.roll(b, 1, hitAt(0, 0)));
		assert app.sent == "\x1bOA\x1bOA\x1bOA";
		b.shutdown();
	}
	const off: Sink = { sent: "" };
	const d = termOf("\x1b[?1049h\x1b[?1007l", 20, 5, off);
	assert d !== null;
	if (d !== null) {
		const c = Controls.open();
		assert c.roll(d, 1, hitAt(0, 0)).ok;
		assert off.sent == "";
		d.shutdown();
	}
}

test "an app that tracks the mouse gets presses, releases and wheel notches as its own reports" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30) + "\x1b[?1000h\x1b[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		const bottom = offsetOf(t);
		assert handled(c.down(t, clip, 1, hitAt(2, 1), 0));
		assert !c.pointer.dragging;
		assert sink.sent == "\x1b[<0;3;2M";
		assert handled(c.up(t, 1, hitAt(2, 1)));
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m";
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert offsetOf(t) == bottom;
		assert sink.sent == "\x1b[<0;3;2M\x1b[<0;3;2m\x1b[<64;1;1M\x1b[<64;1;1M\x1b[<64;1;1M";
		assert !handled(c.up(t, 1, hitAt(0, 0)));
		t.shutdown();
	}
}

test "motion is reported only in the modes that ask for it, and the held button rides along" {
	const sink: Sink = { sent: "" };
	const t = termOf("\x1b[?1002h\x1b[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		assert !handled(c.move(t, hitAt(1, 1), false));
		assert sink.sent == "";
		assert handled(c.down(t, clip, 1, hitAt(1, 1), 0));
		assert !handled(c.move(t, hitAt(4, 1), true));
		assert sink.sent == "\x1b[<0;2;2M\x1b[<32;5;2M";
		t.shutdown();
	}
}

test "shift hands the mouse back from an app that tracks it, to selection and the viewport" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30) + "\x1b[?1000h\x1b[?1006h", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("x"));
		const bottom = offsetOf(t);
		assert handled(c.down(t, clip, 1, hitWith(0, 1, 1), 0));
		assert c.pointer.dragging;
		assert handled(c.move(t, hitWith(5, 1, 1), true));
		assert c.pointer.selected();
		assert sink.sent == "";
		assert handled(c.roll(t, 1, hitWith(0, 0, 1)));
		assert offsetOf(t) == bottom - 3;
		t.shutdown();
	}
}

test "a ctrl click on an http link opens it, on any other link or text it does not" {
	const sink: Sink = { sent: "" };
	const text = "\x1b]8;;https://example.com/a\x07link\x1b]8;;\x07 \x1b]8;;file:///c:/x.exe\x07bad\x1b]8;;\x07 plain";
	const t = termOf(text, 30, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const board = boardOf("");
		const clip = clipOf(board);
		assert handled(c.down(t, clip, 1, hitWith(1, 0, 2), 0));
		assert board.opened == "https://example.com/a";
		board.opened = "";
		assert handled(c.down(t, clip, 1, hitWith(6, 0, 2), 0));
		assert board.opened == "";
		assert handled(c.down(t, clip, 1, hitWith(12, 0, 2), 10000));
		assert board.opened == "";
		assert handled(c.down(t, clip, 1, hitWith(1, 0, 0), 20000));
		assert board.opened == "";
		t.shutdown();
	}
}

test "a clipboard read waits for an answer: escape or enter deny it, ctrl enter allows it" {
	const deny: Sink = { sent: "" };
	const a = termOf("\x1b]52;c;?\x1b\\", 20, 5, deny);
	assert a !== null;
	if (a !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("secret"));
		c.asked(a, clip);
		assert c.holding();
		assert c.reading == "secret";
		assert deny.sent == "";
		assert handled(c.keyDown(a, key("KeyY", 0), clip));
		assert c.holding();
		assert handled(c.keyDown(a, key("Enter", 0), clip));
		assert !c.holding();
		assert deny.sent == "\x1b]52;c;\x1b\\";
		a.shutdown();
	}
	const allow: Sink = { sent: "" };
	const b = termOf("\x1b]52;c;?\x1b\\", 20, 5, allow);
	assert b !== null;
	if (b !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf("secret"));
		c.asked(b, clip);
		assert handled(c.keyDown(b, key("Enter", 2), clip));
		assert allow.sent == "\x1b]52;c;c2VjcmV0\x1b\\";
		b.shutdown();
	}
}

test "an empty clipboard is answered at once and a read does not ask while the pointer is inert" {
	const sink: Sink = { sent: "" };
	const t = termOf("\x1b]52;c;?\x1b\\", 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		c.asked(t, clipOf(boardOf("")));
		assert !c.holding();
		assert sink.sent == "\x1b]52;c;\x1b\\";
		c.reading = "x";
		const clip = clipOf(boardOf(""));
		assert !handled(c.roll(t, 1, hitAt(0, 0)));
		assert !handled(c.down(t, clip, 1, hitAt(0, 0), 0));
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
		assert !handled(c.down(t, clip, 2, hitAt(0, 0), 0));
		assert sink.sent == "pasted";
		assert drag(c, t, clip, at(0, 0), at(4, 0));
		assert handled(c.down(t, clip, 2, hitAt(0, 0), 1000));
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
		assert c.down(t, clip, 1, hitAt(0, 4), 0).ok;
		assert handled(c.move(t, hitAt(3, 4), true));
		assert handled(c.roll(t, 1, hitAt(0, 0)));
		const kept = c.pointer.sel;
		assert kept !== null;
		if (kept !== null) { assert kept.bounds().start.row < kept.bounds().end.row; }
		assert !handled(c.move(t, hitAt(5, 4), false));
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

test "ctrl alt up and down move the viewport between prompts the shell marked" {
	const sink: Sink = { sent: "" };
	const t = termOf("\x1b]133;A\x07p1\r\nout1\r\nout2\r\n\x1b]133;A\x07p2\r\nout3\r\n\x1b]133;A\x07p3", 10, 3, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert handled(c.keyDown(t, key("ArrowUp", 6), clip));
		assert offsetOf(t) < bottom;
		assert handled(c.keyDown(t, key("ArrowDown", 6), clip));
		assert sink.sent == "";
		t.shutdown();
	}
}

test "a drag held past the top edge scrolls back a row per tick, and the release stops it" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		const clip = clipOf(boardOf(""));
		const bottom = offsetOf(t);
		assert c.down(t, clip, 1, hitAt(3, 2), 0).ok;
		const above: Hit = { ...hitAt(3, 0), y: -12 };
		assert c.move(t, above, true).ok;
		assert c.autoscroll == -1;
		assert handled(c.autoscrollTick(t));
		assert handled(c.autoscrollTick(t));
		assert offsetOf(t) == bottom - 2;
		const kept = c.pointer.sel;
		assert kept !== null;
		if (kept !== null) { assert kept.bounds().start.row == bottom - 2; }
		assert c.up(t, 1, above).ok;
		assert !handled(c.autoscrollTick(t));
		assert offsetOf(t) == bottom - 2;
		t.shutdown();
	}
}

test "a configured keybind sends its text, ahead of a built-in chord on the same keys" {
	const sink: Sink = { sent: "" };
	const t = termOf(lines(30), 20, 5, sink);
	assert t !== null;
	if (t !== null) {
		const c = Controls.open();
		c.keybinds = [
			{ code: "Enter", mods: SHIFT, text: "[13;2u", action: BindAction.SendText, screen: Screen.Any },
			{ code: "KeyC", mods: CTRL | SHIFT, text: "c", action: BindAction.SendText, screen: Screen.Any },
		];
		const clip = clipOf(boardOf(""));
		assert handled(c.keyDown(t, key("PageUp", 3), clip));
		assert handled(c.keyDown(t, key("Enter", 1), clip));
		assert sink.sent == "[13;2u";
		assert atBottomOf(t);
		assert handled(c.keyDown(t, key("KeyC", 3), clip));
		assert sink.sent == "[13;2uc";
		assert !handled(c.keyDown(t, key("Enter", 2), clip));
		t.shutdown();
	}
}

test "a keybind with a mode sends to a full-screen program and closes the window at the shell" {
	const binds: Vec<Keybind> = [
		{ code: "KeyW", mods: SUPER, text: "\x1b[119;9u", action: BindAction.SendText, screen: Screen.Alternate },
		{ code: "KeyW", mods: SUPER, text: "", action: BindAction.CloseWindow, screen: Screen.Primary },
	];
	const atShell: Sink = { sent: "" };
	const shell = termOf("$ ", 20, 5, atShell);
	const inApp: Sink = { sent: "" };
	const app = termOf("\x1b[?1049h", 20, 5, inApp);
	assert shell !== null && app !== null;
	if (shell !== null && app !== null) {
		const c = Controls.open();
		c.keybinds = binds;
		const board = boardOf("");
		const clip = clipOf(board);
		assert handled(c.keyDown(app, key("KeyW", SUPER), clip));
		assert inApp.sent == "\x1b[119;9u";
		assert board.closed == 0;
		assert handled(c.keyDown(shell, key("KeyW", SUPER), clip));
		assert atShell.sent == "";
		assert board.closed == 1;
		shell.shutdown();
		app.shutdown();
	}
}
