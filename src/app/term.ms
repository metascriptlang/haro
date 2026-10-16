import { createList, List } from "../../../neon/src/core/list";
import { NeonEvent } from "../../../neon/src/render/event";
import { Style } from "../../../neon/src/render/style";
import { KeyAction, KeyEvent, KeyMod } from "../keys/keys";
import { Pty, PtyError } from "../pty/transport";
import { Replay } from "../pty/replay";
import { Session } from "../session/session";
import { Cursor, Keys } from "../vt/vt";
import { FrameError, RowSlot, applyFrame } from "./frame";

const BUFFER_BYTES = 65536;
const DRAIN_LIMIT = 16;

export enum TermError {
	KeysOpenFailed,
	PtyOpenFailed,
	SessionStartFailed,
	ResizeFailed,
	PumpFailed,
	FramePlanFailed,
	FrameCursorFailed,
	FramePaletteFailed,
	FrameLineFailed,
	EncodeFailed,
	TextTooLong,
	WriteFailed,
}

export type OpenPty = (cols: int32, rows: int32) => Result<Pty, PtyError>;

export interface Term {
	open: OpenPty;
	session: Session | null;
	keys: Keys;
	grid: List<RowSlot>;
	styles: Map<string, Style>;
	buf: Vec<uint8>;
	cols: int32;
	rows: int32;
	alive: boolean;
	ended: boolean;
}

export struct Frame {
	cursor: Cursor | null;
	more: boolean;
	ended: boolean;
}

export function openTerm(open: OpenPty): Result<Term, TermError> {
	const keys = Keys.openKeys();
	if (!keys.ok) { return Result.err(TermError.KeysOpenFailed); }
	const buf: Vec<uint8> = new Array(BUFFER_BYTES);
	return Result.ok({
		open: open,
		session: null,
		keys: keys.value,
		grid: createList<RowSlot>([]),
		styles: new Map<string, Style>(),
		buf: buf,
		cols: 0,
		rows: 0,
		alive: true,
		ended: false,
	});
}

function blankSlot(): RowSlot {
	return { line: { text: "", runs: [], cursorCell: -1 }, spans: [] };
}

function matchGrid(this t: Term, rows: int32): void {
	const have = t.grid.length() as int32;
	for (let i = have; i < rows; i++) { t.grid.push(blankSlot()); }
	for (let i = have; i > rows; i--) { t.grid.remove(i - 1); }
}

export function fit(this t: Term, cols: int32, rows: int32): Result<boolean, TermError> {
	const s = t.session;
	if (s === null) {
		const pty = t.open(cols, rows);
		if (!pty.ok) { return Result.err(TermError.PtyOpenFailed); }
		const started = Session.start(pty.value, cols, rows);
		if (!started.ok) { return Result.err(TermError.SessionStartFailed); }
		t.session = started.value;
	} else {
		if (cols == t.cols && rows == t.rows) { return Result.ok(false); }
		if (!s.resize(cols, rows).ok) { return Result.err(TermError.ResizeFailed); }
	}
	t.cols = cols;
	t.rows = rows;
	t.matchGrid(rows);
	return Result.ok(true);
}

function frameFailure(error: FrameError): TermError {
	return match (error) {
		FrameError.PlanFailed => TermError.FramePlanFailed,
		FrameError.CursorFailed => TermError.FrameCursorFailed,
		FrameError.PaletteFailed => TermError.FramePaletteFailed,
		FrameError.LineFailed => TermError.FrameLineFailed,
	};
}

export function drain(this t: Term): Result<boolean, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(false); }
	let more = false;
	for (let i = 0; i < DRAIN_LIMIT && t.alive; i++) {
		const ready = s.pty.wait(0);
		if (!ready.ok) { return Result.err(TermError.PumpFailed); }
		if (!ready.value) { break; }
		const alive = s.pump(t.buf);
		if (!alive.ok) { return Result.err(TermError.PumpFailed); }
		if (!alive.value) {
			t.alive = false;
			t.ended = true;
		}
		more = alive.value && i == DRAIN_LIMIT - 1;
	}
	return Result.ok(more);
}

export function pumpFrame(this t: Term): Result<Frame, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok({ cursor: null, more: false, ended: false }); }
	const more = try t.drain();
	const ended = t.ended;
	t.ended = false;
	const applied = applyFrame(t.grid, t.styles, s.vt);
	if (!applied.ok) { return Result.err(frameFailure(applied.error)); }
	return Result.ok({ cursor: applied.value, more: more, ended: ended });
}

export function sendKey(this t: Term, e: NeonEvent): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const key: KeyEvent = {
		action: e.repeat ? KeyAction.Repeat : KeyAction.Press,
		key: e.code,
		mods: (e.mods as uint16) as BitSet<KeyMod>,
		consumedMods: (e.consumedMods as uint16) as BitSet<KeyMod>,
		unshifted: e.unshifted as uint32,
		text: e.text,
	};
	const encoded = t.keys.encode(s.vt, key, t.buf);
	if (!encoded.ok) { return Result.err(TermError.EncodeFailed); }
	if (encoded.value == 0) { return Result.ok(0); }
	if (!s.pty.write(t.buf[0..encoded.value]).ok) { return Result.err(TermError.WriteFailed); }
	return Result.ok(encoded.value);
}

export function sendText(this t: Term, text: string): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const n = text.byteLength as int32;
	if (n > BUFFER_BYTES) { return Result.err(TermError.TextTooLong); }
	if (n == 0) { return Result.ok(0); }
	const bytes: Readonly<Span<char>> = text;
	for (let i = 0; i < n; i++) { t.buf[i] = bytes[i] as uint8; }
	if (!s.pty.write(t.buf[0..n]).ok) { return Result.err(TermError.WriteFailed); }
	return Result.ok(n);
}

export function shutdown(this t: Term): void {
	const s = t.session;
	if (s !== null) {
		s.close();
		t.session = null;
	}
	t.keys.freeKeys();
}

export function shellExitCode(this t: Term): int32 {
	const s = t.session;
	if (s === null) { return 0; }
	const code = s.pty.exitCode();
	if (code === null) { return 0; }
	return code;
}

test "output drained ahead of the frame shows in the grid only when the frame applies it" {
	const replay = Replay.ofText("one\r\ntwo");
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		return Result.ok(replay.toPty());
	});
	assert opened.ok;
	if (opened.ok) {
		const t = opened.value;
		assert t.fit(20, 3).ok;
		const drained = t.drain();
		assert drained.ok;
		if (drained.ok) { assert !drained.value; }
		assert !t.alive;
		assert t.grid.at(0).line.text.trimEnd() == "";
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			assert frame.value.ended;
			assert !frame.value.more;
		}
		assert t.grid.at(0).line.text.trimEnd() == "one";
		assert t.grid.at(1).line.text.trimEnd() == "two";
		const next = t.pumpFrame();
		assert next.ok;
		if (next.ok) { assert !next.value.ended; }
		t.shutdown();
	}
}

test "a replayed recording fills the grid in one frame and ends the stream once" {
	const replay = Replay.ofText("one\r\n\x1b[31mtwo\x1b[0m");
	let openedCols = 0;
	const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
		openedCols = cols;
		return Result.ok(replay.toPty());
	});
	assert opened.ok;
	if (opened.ok) {
		const t = opened.value;
		assert openedCols == 0;
		const fitted = t.fit(20, 3);
		assert fitted.ok;
		assert openedCols == 20;
		assert t.grid.length() == 3;
		const first = t.pumpFrame();
		assert first.ok;
		if (first.ok) {
			assert first.value.ended;
			assert !first.value.more;
			assert first.value.cursor !== null;
		}
		assert t.grid.at(0).line.text.trimEnd() == "one";
		assert t.grid.at(1).line.text.trimEnd() == "two";
		assert t.grid.at(1).spans[0].text == "two";
		assert t.grid.at(2).line.text.trimEnd() == "";
		const second = t.pumpFrame();
		assert second.ok;
		if (second.ok) { assert !second.value.ended; }
		assert !t.alive;
		assert t.shellExitCode() == 0;
		t.shutdown();
	}
}
