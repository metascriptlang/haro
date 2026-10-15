import { createList, List } from "../../../neon/src/core/list";
import { NeonEvent } from "../../../neon/src/render/event";
import { Style } from "../../../neon/src/render/style";
import { KeyAction, KeyEvent, KeyMod } from "../keys/keys";
import { Pty } from "../pty/pty";
import { Session } from "../session/session";
import { Cursor, Keys } from "../vt/vt";
import { FrameError, RowSlot, applyFrame } from "./frame";

const BUFFER_BYTES = 65536;
const DRAIN_LIMIT = 16;

export enum TermError {
	KeysOpenFailed,
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

export interface Term {
	shell: string;
	session: Session | null;
	keys: Keys;
	grid: List<RowSlot>;
	styles: Map<string, Style>;
	buf: Vec<uint8>;
	cols: int32;
	rows: int32;
	alive: boolean;
}

export struct Frame {
	cursor: Cursor | null;
	more: boolean;
}

export function openTerm(shell: string): Result<Term, TermError> {
	const keys = Keys.openKeys();
	if (!keys.ok) { return Result.err(TermError.KeysOpenFailed); }
	const buf: Vec<uint8> = new Array(BUFFER_BYTES);
	return Result.ok({
		shell: shell,
		session: null,
		keys: keys.value,
		grid: createList<RowSlot>([]),
		styles: new Map<string, Style>(),
		buf: buf,
		cols: 0,
		rows: 0,
		alive: true,
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
		const started = Session.start(t.shell, cols, rows);
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

export function pumpFrame(this t: Term): Result<Frame, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok({ cursor: null, more: false }); }
	let more = false;
	for (let i = 0; i < DRAIN_LIMIT && t.alive; i++) {
		const ready = s.pty.wait(0);
		if (!ready.ok) { return Result.err(TermError.PumpFailed); }
		if (!ready.value) { break; }
		const alive = s.pump(t.buf);
		if (!alive.ok) { return Result.err(TermError.PumpFailed); }
		if (!alive.value) { t.alive = false; }
		more = alive.value && i == DRAIN_LIMIT - 1;
	}
	const applied = applyFrame(t.grid, t.styles, s.vt);
	if (!applied.ok) { return Result.err(frameFailure(applied.error)); }
	return Result.ok({ cursor: applied.value, more: more });
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
