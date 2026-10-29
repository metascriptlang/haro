import { MouseButton } from "./mouseButton";
import { KeyAction, KeyEvent, KeyMod, NO_MODS, keyEvent } from "../keys/keys";
import { Spot } from "../input/pointer";
import { Pty, PtyError } from "../pty/transport";
import { Replay } from "../pty/replay";
import { atBottom, geometryOf, scrollOffset } from "../vt/vt";
import { Term, TermError, openTerm } from "./term";
import { Controls, Hit, takeAsks } from "./controls";
import { clipboardText } from "./clipboard";
import { pointerDown, pointerMove, pointerUp } from "./mouse";

export interface Sink {
	sent: string;
	busy: boolean;
}

function recorder(text: string, sink: Sink): Pty {
	return {
		...Replay.ofText(text).toPty(),
		write: (data: Readonly<Span<uint8>>): Result<void, PtyError> => {
			sink.sent += data.asString();
			return Result.ok(null);
		},
		busy: (): boolean => { return sink.busy; },
	};
}

export function exiting(text: string, code: int32, signal: int32): Pty {
	return {
		...Replay.ofText(text).toPty(),
		exitCode: (): int32 | null => { return code; },
		exitSignal: (): int32 => { return signal; },
	};
}

export function onPty(
	pty: Pty,
	now: () => float64,
	cols: int32,
	rows: int32,
	body: (t: Term) => void,
): Result<void, TermError> {
	const opener = (c: int32, r: int32): Result<Pty, PtyError> => { return Result.ok(pty); };
	const t = try openTerm(opener, now);
	defer t.shutdown();
	const _fit = try t.fit(cols, rows);
	body(t);
	return Result.ok(null);
}

export function onUnfit(
	text: string,
	body: (t: Term, sink: Sink) => void,
): Result<void, TermError> {
	const sink: Sink = { sent: "", busy: false };
	const t = try openTerm((c: int32, r: int32): Result<Pty, PtyError> => {
		return Result.ok(recorder(text, sink));
	});
	defer t.shutdown();
	body(t, sink);
	return Result.ok(null);
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

export function key(code: string, mods: BitSet<KeyMod>): KeyEvent {
	return keyEvent(KeyAction.Press, code, mods);
}

export function lines(n: int32): string {
	let out = "";
	for (let i = 1; i <= n; i++) { out += `line ${i}\r\n`; }
	return out;
}

export function offsetOf(t: Term): int32 {
	const s = t.session;
	if (s === null) { throw new Error("offsetOf: the terminal has no session"); }
	const offset = s.vt.scrollOffset();
	if (!offset.ok) { throw new Error(`offsetOf: ${offset.error}`); }
	return offset.value;
}

export function atBottomOf(t: Term): boolean {
	const s = t.session;
	if (s === null) { throw new Error("atBottomOf: the terminal has no session"); }
	const bottom = s.vt.atBottom();
	if (!bottom.ok) { throw new Error(`atBottomOf: ${bottom.error}`); }
	return bottom.value;
}

export function spotAt(col: int32, row: int32): Spot {
	return { col: col, row: row };
}

export function handled(r: Result<boolean, TermError>): boolean {
	return r.ok && r.value;
}

export function hitAt(col: int32, row: int32): Hit {
	return hitWith(col, row, NO_MODS);
}

export function hitWith(col: int32, row: int32, mods: BitSet<KeyMod>): Hit {
	return {
		at: spotAt(col, row),
		x: col as float64 * 8,
		y: row as float64 * 16,
		scale: 1,
		mods: mods,
		cell: geometryOf(8, 16, 160, 80),
	};
}

export function drag(c: Controls, t: Term, clip: Board, from: Spot, to: Spot): boolean {
	const down = c.pointerDown(t, MouseButton.Left, hitAt(from.col, from.row), 0);
	const pressed = settled(clip, c, t, down).ok;
	const moved = c.pointerMove(t, hitAt(to.col, to.row), true).ok;
	const released = c.pointerUp(t, MouseButton.Left, hitAt(to.col, to.row)).ok;
	return pressed && moved && released;
}
