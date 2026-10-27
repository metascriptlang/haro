import { MouseButton } from "../../../mouseButton";
import { KeyAction, KeyEvent, modsOf } from "../../../../keys/keys";
import { Spot } from "../../../../input/pointer";
import { Pty, PtyError } from "../../../../pty/transport";
import { Replay } from "../../../../pty/replay";
import { atBottom, scrollOffset } from "../../../../vt/vt";
import { Term, TermError, openTerm } from "./term";
import { Controls, Hit, takeAsks } from "./controls";
import { clipboardText } from "./clipboard";
import { pointerDown, pointerMove, pointerUp } from "./mouse";

export interface Sink {
	sent: string;
	busy: boolean;
}

function recorder(text: string, sink: Sink): Pty {
	const base = Replay.ofText(text).toPty();
	return {
		wait: base.wait,
		read: base.read,
		write: (data: Readonly<Span<uint8>>): Result<int32, PtyError> => {
			sink.sent += data.asString();
			return Result.ok(data.length as int32);
		},
		resize: base.resize,
		exitCode: base.exitCode,
		exitSignal: base.exitSignal,
		close: base.close,
		busy: (): boolean => { return sink.busy; },
	};
}

function onFitted(
	text: string,
	pump: boolean,
	cols: int32,
	rows: int32,
	body: (t: Term, sink: Sink) => void,
): Result<void, TermError> {
	const sink: Sink = { sent: "", busy: false };
	const t = try openTerm((c: int32, r: int32): Result<Pty, PtyError> => {
		return Result.ok(recorder(text, sink));
	});
	defer t.shutdown();
	const _fit = try t.fit(cols, rows);
	if (pump) { const _frame = try t.pumpFrame(); }
	body(t, sink);
	return Result.ok(null);
}

export function onTerm(
	text: string,
	body: (t: Term, sink: Sink) => void,
	cols: int32 = 20,
	rows: int32 = 5,
): Result<void, TermError> {
	return onFitted(text, true, cols, rows, body);
}

export function onFresh(
	text: string,
	body: (t: Term, sink: Sink) => void,
): Result<void, TermError> {
	return onFitted(text, false, 20, 5, body);
}

export interface Board {
	opened: string;
	copied: string;
	offer: string;
	reads: int32;
	closed: int32;
}

export function boardOf(offer: string): Board {
	return { opened: "", copied: "", offer: offer, reads: 0, closed: 0 };
}

export function settle(this board: Board, c: Controls, t: Term): Result<void, TermError> {
	const asks = c.takeAsks();
	const copy = asks.copy;
	if (copy !== null) { board.copied = copy; }
	for (const uri of asks.opens) { board.opened = uri; }
	if (asks.close) { board.closed += 1; }
	for (let i = 0; i < asks.reads; i++) {
		board.reads += 1;
		const _answered = try c.clipboardText(t, board.offer);
	}
	return Result.ok(null);
}

export function settled(
	board: Board,
	c: Controls,
	t: Term,
	r: Result<boolean, TermError>,
): Result<boolean, TermError> {
	const _settled = try board.settle(c, t);
	return r;
}

export function key(code: string, mods: int32): KeyEvent {
	return {
		action: KeyAction.Press,
		key: code,
		mods: modsOf(mods),
		consumedMods: modsOf(0),
		unshifted: 0,
		text: "",
	};
}

export function lines(n: int32): string {
	let out = "";
	for (let i = 1; i <= n; i++) { out += `line ${i}\r\n`; }
	return out;
}

export function offsetOf(t: Term): int32 {
	const s = t.session;
	if (s === null) { return -1; }
	return try s.vt.scrollOffset() catch -1;
}

export function atBottomOf(t: Term): boolean {
	const s = t.session;
	if (s === null) { return false; }
	return try s.vt.atBottom() catch false;
}

export function at(col: int32, row: int32): Spot {
	return { col: col, row: row };
}

export function handled(r: Result<boolean, TermError>): boolean {
	return r.ok && r.value;
}

export function hitAt(col: int32, row: int32): Hit {
	return hitWith(col, row, 0);
}

export function hitWith(col: int32, row: int32, mods: int32): Hit {
	return {
		at: at(col, row),
		x: col as float64 * 8,
		y: row as float64 * 16,
		scale: 1,
		mods: modsOf(mods),
		cell: {
			cellWidth: 8,
			cellHeight: 16,
			width: 160,
			height: 80,
			padLeft: 0,
			padTop: 0,
			padRight: 0,
			padBottom: 0,
		},
	};
}

export function drag(c: Controls, t: Term, clip: Board, from: Spot, to: Spot): boolean {
	const pressed = settled(clip, c, t, c.pointerDown(t, MouseButton.Left, hitAt(from.col, from.row), 0)).ok;
	const moved = c.pointerMove(t, hitAt(to.col, to.row), true).ok;
	const _released = c.pointerUp(t, MouseButton.Left, hitAt(to.col, to.row));
	return pressed && moved;
}
