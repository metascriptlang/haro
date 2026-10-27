import {
	KeyAction,
	KeyEvent,
	KeyMod,
	heldAfter,
	releasesOf,
	withNumLockApplied,
	withoutAltGr,
} from "../../../../keys/keys";
import { Pty, PtyError } from "../../../../pty/transport";
import { Replay } from "../../../../pty/replay";
import { Session } from "../../../../session/session";
import { CellInk } from "../../../../grid/lines";
import {
	Cursor,
	CursorLook,
	CursorShape,
	DesktopNotification,
	Keys,
	MouseGeometry,
	MouseInput,
	PasteError,
	Palette,
} from "../../../../vt/vt";
import {
	FrameError,
	FrameRows,
	Shown,
	View,
	fitRows,
	fitShown,
	open,
	paint,
	planRows,
	relitRows,
	text,
} from "../../../frame";
import { stats, mark } from "../../../stats";

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
	FrameLineFailed,
	EncodeFailed,
	WriteFailed,
	PasteUnsafe,
	PasteEncodeFailed,
	FrameLookFailed,
	EventsFailed,
	FocusFailed,
	MouseFailed,
	VtFailed,
	ClipboardUnasked,
}

export type OpenPty = (
	cols: int32,
	rows: int32,
	cellWidth: int32,
	cellHeight: int32,
) => Result<Pty, PtyError>;

export interface Term {
	open: OpenPty;
	session: Session | null;
	keys: Keys;
	held: KeyEvent | null;
	shown: Vec<Shown>;
	cursorInk: CellInk | null;
	buf: Vec<uint8>;
	cols: int32;
	rows: int32;
	cellWidth: int32;
	cellHeight: int32;
	alive: boolean;
	ended: boolean;
	spawnedAt: number;
}

export struct Frame {
	rows: FrameRows | null;
	cursor: Cursor | null;
	look: CursorLook;
	colors: Palette | null;
	more: boolean;
	ended: boolean;
	held: boolean;
	copied: string | null;
	asked: boolean;
	bells: int32;
	title: string | null;
	notification: DesktopNotification | null;
}

const HIDDEN: CursorLook = { visible: false, shape: CursorShape.Block, blinking: false };

function idleFrame(more: boolean, ended: boolean): Frame {
	return {
		rows: null,
		cursor: null,
		look: HIDDEN,
		colors: null,
		more: more,
		ended: ended,
		held: false,
		copied: null,
		asked: false,
		bells: 0,
		title: null,
		notification: null,
	};
}

export function openTerm(open: OpenPty): Result<Term, TermError> {
	const keys = Keys.openKeys();
	if (!keys.ok) { return Result.err(TermError.KeysOpenFailed); }
	const buf: Vec<uint8> = new Array(BUFFER_BYTES);
	return Result.ok({
		open: open,
		session: null,
		keys: keys.value,
		held: null,
		shown: [],
		cursorInk: null,
		buf: buf,
		cols: 0,
		rows: 0,
		cellWidth: 0,
		cellHeight: 0,
		alive: true,
		ended: false,
		spawnedAt: -1,
	});
}

function resizeGrid(this t: Term, rows: int32): void {
	fitShown(t.shown, rows);
}

export function fit(
	this t: Term,
	cols: int32,
	rows: int32,
	cellWidth: int32 = 0,
	cellHeight: int32 = 0,
): Result<boolean, TermError> {
	const s = t.session;
	if (s === null) {
		stats.mark("layout", Date.now());
		const pty = t.open(cols, rows, cellWidth, cellHeight);
		if (!pty.ok) { return Result.err(TermError.PtyOpenFailed); }
		stats.mark("spawned", Date.now());
		t.spawnedAt = performance.now();
		const started = Session.start(pty.value, cols, rows, cellWidth, cellHeight);
		if (!started.ok) { return Result.err(TermError.SessionStartFailed); }
		t.session = started.value;
	} else {
		const sameCell = cellWidth == t.cellWidth && cellHeight == t.cellHeight;
		if (cols == t.cols && rows == t.rows && sameCell) { return Result.ok(false); }
		if (!s.resize(cols, rows, cellWidth, cellHeight).ok) {
			return Result.err(TermError.ResizeFailed);
		}
	}
	t.cols = cols;
	t.rows = rows;
	t.cellWidth = cellWidth;
	t.cellHeight = cellHeight;
	t.resizeGrid(rows);
	return Result.ok(true);
}

function frameFailure(error: FrameError): TermError {
	return match (error) {
		FrameError.PlanFailed => TermError.FramePlanFailed,
		FrameError.CursorFailed => TermError.FrameCursorFailed,
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
	if (s === null) { return Result.ok(idleFrame(false, false)); }
	const more = try t.drain();
	const ended = t.ended;
	const vt = s.vt;
	const events = vt.takeEvents();
	const copied = vt.takeClipboard();
	let title: string | null = null;
	if (events.titleChanged) {
		const named = vt.title();
		if (!named.ok) { return Result.err(TermError.EventsFailed); }
		title = named.value;
	}
	const asked = vt.clipboardAsked();
	if (vt.holding()) {
		t.ended = false;
		return Result.ok({
			...idleFrame(more, ended),
			held: true,
			copied: copied,
			asked: asked,
			bells: events.bells,
			title: title,
			notification: events.notification,
		});
	}
	const planned = planRows(t.shown, vt, t.cursorInk);
	if (!planned.ok) { return Result.err(frameFailure(planned.error)); }
	const look = vt.cursorLook();
	if (!look.ok) { return Result.err(TermError.FrameLookFailed); }
	t.ended = false;
	return Result.ok({
		rows: planned.value.rows,
		cursor: planned.value.cursor,
		look: look.value,
		colors: vt.painted.palette,
		more: more,
		ended: ended,
		held: false,
		copied: copied,
		asked: asked,
		bells: events.bells,
		title: title,
		notification: events.notification,
	});
}

export function inkCursor(this t: Term, ink: CellInk | null): Result<FrameRows, TermError> {
	t.cursorInk = ink;
	const s = t.session;
	if (s === null) { return Result.ok(FrameRows.none()); }
	const relit = relitRows(t.shown, s.vt, ink);
	if (!relit.ok) { return Result.err(frameFailure(relit.error)); }
	return Result.ok(relit.value);
}

function sendBytes(s: Session, bytes: Span<uint8>): Result<int32, TermError> {
	if (bytes.length == 0) { return Result.ok(0); }
	if (!s.send(bytes).ok) { return Result.err(TermError.WriteFailed); }
	return Result.ok(bytes.length as int32);
}

function sendBuffered(this t: Term, s: Session, n: int32): Result<int32, TermError> {
	return sendBytes(s, t.buf[0..n]);
}

export function cooked(this key: KeyEvent): KeyEvent {
	when (windows) {
		return key.withoutAltGr().withNumLockApplied();
	} else {
		return key.withoutAltGr();
	}
}

function sendKeyEvent(this t: Term, s: Session, key: KeyEvent): Result<int32, TermError> {
	const encoded = t.keys.encode(s.vt, key, t.buf);
	if (!encoded.ok) { return Result.err(TermError.EncodeFailed); }
	return t.sendBuffered(s, encoded.value);
}

export function sendKey(this t: Term, typed: KeyEvent): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const key = typed.cooked();
	t.held = heldAfter(t.held, key);
	return t.sendKeyEvent(s, key);
}

export function tapKey(this t: Term, code: string): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const press: KeyEvent = {
		action: KeyAction.Press,
		key: code,
		mods: 0 as BitSet<KeyMod>,
		consumedMods: 0 as BitSet<KeyMod>,
		unshifted: 0,
		text: "",
	};
	const pressed = try t.sendKeyEvent(s, press);
	const released = try t.sendKeyEvent(s, { ...press, action: KeyAction.Release });
	return Result.ok(pressed + released);
}

export function releaseHeldKey(this t: Term): Result<int32, TermError> {
	const s = t.session;
	const held = t.held;
	t.held = null;
	if (s === null || held === null) { return Result.ok(0); }
	let sent = 0;
	for (const key of releasesOf(held)) { sent += try t.sendKeyEvent(s, key); }
	return Result.ok(sent);
}

export function sendText(this t: Term, text: string): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const bytes = text.asBytes();
	const n = bytes.length as int32;
	if (n == 0) { return Result.ok(0); }
	if (!s.send(bytes).ok) { return Result.err(TermError.WriteFailed); }
	return Result.ok(n);
}

export function sendPaste(
	this t: Term,
	text: string,
	allowUnsafe: boolean,
): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const bytes = s.vt.pasteBytes(text, allowUnsafe);
	if (!bytes.ok) {
		return Result.err(match (bytes.error) {
			PasteError.Unsafe => TermError.PasteUnsafe,
			PasteError.EncodeFailed => TermError.PasteEncodeFailed,
		});
	}
	return sendBytes(s, bytes.value);
}

export function sendFocus(this t: Term, gained: boolean): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const n = s.vt.focusReport(gained, t.buf);
	if (!n.ok) { return Result.err(TermError.FocusFailed); }
	return t.sendBuffered(s, n.value);
}

export function sendMouse(
	this t: Term,
	e: MouseInput,
	g: MouseGeometry,
	anyPressed: boolean,
): Result<int32, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(0); }
	const n = s.vt.mouseReport(e, g, anyPressed, t.buf);
	if (!n.ok) { return Result.err(TermError.MouseFailed); }
	return t.sendBuffered(s, n.value);
}

export function sendReplies(this t: Term): Result<void, TermError> {
	const s = t.session;
	if (s === null) { return Result.ok(null); }
	if (!s.sendReplies().ok) { return Result.err(TermError.WriteFailed); }
	return Result.ok(null);
}

export function shutdown(this t: Term): void {
	const s = t.session;
	if (s !== null) {
		s.close();
		t.session = null;
	}
	t.keys.freeKeys();
}

export function busy(this t: Term): boolean {
	const s = t.session;
	if (s === null) { return false; }
	return s.pty.busy();
}

export const ABNORMAL_EXIT_MS: number = 250;

export function exitedAbnormally(this t: Term): boolean {
	return t.shellExitCode() != 0 && performance.now() - t.spawnedAt <= ABNORMAL_EXIT_MS;
}

export function shellExitCode(this t: Term): int32 {
	const s = t.session;
	if (s === null) { return 0; }
	const code = s.pty.exitCode();
	if (code === null) { return 0; }
	return code;
}

const BYTE_MAX: int32 = 255;

export function shellExitSignal(this t: Term): int32 {
	const s = t.session;
	if (s === null) { return 0; }
	return s.pty.exitSignal();
}

export function exitCodeText(code: int32): string {
	if (code >= 0 && code <= BYTE_MAX) { return `${code}`; }
	const status = code as uint32;
	return `${status} (0x${status.toString(16).padStart(8, "0")})`;
}

test "an exit code past a byte reads as the unsigned status with its hex, as Windows reports one" {
	assert exitCodeText(0) == "0";
	assert exitCodeText(127) == "127";
	assert exitCodeText(-1073741510) == "3221225786 (0xc000013a)";
	assert exitCodeText(-1) == "4294967295 (0xffffffff)";
	assert exitCodeText(259) == "259 (0x00000103)";
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
		const view = View.open();
		view.fitRows(3);
		const drained = t.drain();
		assert drained.ok;
		if (drained.ok) { assert !drained.value; }
		assert !t.alive;
		assert view.text(0) == "";
		const frame = t.pumpFrame();
		assert frame.ok;
		if (frame.ok) {
			assert frame.value.ended;
			assert !frame.value.more;
			const rows = frame.value.rows;
			if (rows !== null) { view.paint(rows); }
		}
		assert view.text(0) == "one";
		assert view.text(1) == "two";
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
		assert t.shown.length == 3;
		const view = View.open();
		view.fitRows(3);
		const first = t.pumpFrame();
		assert first.ok;
		if (first.ok) {
			assert first.value.ended;
			assert !first.value.more;
			assert first.value.cursor !== null;
			const rows = first.value.rows;
			if (rows !== null) { view.paint(rows); }
		}
		assert view.text(0) == "one";
		assert view.text(1) == "two";
		assert view.grid.at(1).spans[0].text == "two";
		assert view.text(2) == "";
		const second = t.pumpFrame();
		assert second.ok;
		if (second.ok) { assert !second.value.ended; }
		assert !t.alive;
		assert t.shellExitCode() == 0;
		t.shutdown();
	}
}

function exitingWith(code: int32): Pty {
	const base = Replay.ofText("boom").toPty();
	return { ...base, exitCode: (): int32 | null => { return code; } };
}

test "a shell that fails as it starts ended abnormally; a clean or a late exit did not" {
	for (const code of [1, 0]) {
		const opened = openTerm((cols: int32, rows: int32): Result<Pty, PtyError> => {
			return Result.ok(exitingWith(code));
		});
		assert opened.ok;
		if (opened.ok) {
			const t = opened.value;
			assert t.fit(20, 3).ok;
			assert t.exitedAbnormally() == (code != 0);
			t.spawnedAt -= ABNORMAL_EXIT_MS + 1;
			assert !t.exitedAbnormally();
			t.shutdown();
		}
	}
}
