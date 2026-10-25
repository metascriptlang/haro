import { NeonEvent, neonEvent } from "../../../../../../neon/src/render/event";
import { modsOf } from "../../../../keys/keys";
import { Spot } from "../../../../input/pointer";
import { Pty, PtyError } from "../../../../pty/transport";
import { Replay } from "../../../../pty/replay";
import { atBottom, scrollOffset } from "../../../../vt/vt";
import { Term, TermError, openTerm } from "./term";
import { Bridge, Controls, Hit } from "./controls";
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

export function clipOf(board: Board): Bridge {
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

export function key(code: string, mods: int32): NeonEvent {
	const e = neonEvent("keydown");
	e.code = code;
	e.mods = mods;
	return e;
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

export function drag(c: Controls, t: Term, clip: Bridge, from: Spot, to: Spot): boolean {
	const pressed = c.pointerDown(t, clip, 1, hitAt(from.col, from.row), 0).ok;
	const moved = c.pointerMove(t, hitAt(to.col, to.row), true).ok;
	const _released = c.pointerUp(t, 1, hitAt(to.col, to.row));
	return pressed && moved;
}
